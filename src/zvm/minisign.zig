const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Io = std.Io;

//

const zig_public_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

const ParsedSignature = struct {
    signature: Ed25519.Signature,
    trusted_comment: []const u8,
    global_signature: Ed25519.Signature,
};

pub fn verifyFile(io: Io, path: []const u8, signature_text: []const u8) !void {
    const parsed = try parseSignature(signature_text);

    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader_buf: [1 << 16]u8 = undefined;
    var reader = file.reader(io, &file_reader_buf);
    var hash = std.crypto.hash.blake2.Blake2b512.init(.{});
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        hash.update(chunk[0..n]);
    }

    var digest: [std.crypto.hash.blake2.Blake2b512.digest_length]u8 = undefined;
    hash.final(&digest);
    try verifyDigest(parsed, &digest, try zigPublicKey());
}

fn parseSignature(text: []const u8) !ParsedSignature {
    const trusted_comment_prefix = "trusted comment: ";
    
    var lines = std.mem.splitScalar(u8, text, '\n');
    const untrusted = trimCr(lines.next() orelse
        return error.InvalidMinisignSignature);
    if (!std.mem.startsWith(u8, untrusted, "untrusted comment: "))
        return error.InvalidMinisignSignature;

    const encoded_signature = trimCr(lines.next() orelse
        return error.InvalidMinisignSignature);
    const trusted_line = trimCr(lines.next() orelse
        return error.InvalidMinisignSignature);
    if (!std.mem.startsWith(u8, trusted_line, trusted_comment_prefix))
        return error.InvalidMinisignSignature;

    const encoded_global = trimCr(lines.next() orelse return error.InvalidMinisignSignature);
    while (lines.next()) |extra| {
        if (trimCr(extra).len != 0) return error.InvalidMinisignSignature;
    }

    const signed = try decodeFixed(74, encoded_signature);
    if (!std.mem.eql(u8, signed[0..2], "ED"))
        return error.UnsupportedMinisignAlgorithm;

    const key = try zigPublicKeyBytes();
    if (!std.mem.eql(u8, signed[2..10], key[2..10]))
        return error.UnknownMinisignKey;

    const global = try decodeFixed(64, encoded_global);

    return .{
        .signature = Ed25519.Signature.fromBytes(signed[10..74].*),
        .trusted_comment = trusted_line[trusted_comment_prefix.len..],
        .global_signature = Ed25519.Signature.fromBytes(global),
    };
}

fn verifyDigest(parsed: ParsedSignature, digest: []const u8, public_key: Ed25519.PublicKey) !void {
    parsed.signature.verify(digest, public_key) catch
        return error.InvalidArchiveSignature;

    const signature_bytes = parsed.signature.toBytes();
    var verifier = parsed.global_signature.verifier(public_key) catch
        return error.InvalidGlobalSignature;
    verifier.update(&signature_bytes);
    verifier.update(parsed.trusted_comment);
    verifier.verify() catch
        return error.InvalidGlobalSignature;
}

fn zigPublicKey() !Ed25519.PublicKey {
    const encoded = try zigPublicKeyBytes();

    return Ed25519.PublicKey.fromBytes(encoded[10..42].*) catch
        return error.InvalidMinisignPublicKey;
}

fn zigPublicKeyBytes() ![42]u8 {
    const encoded = try decodeFixed(42, zig_public_key);
    if (!std.mem.eql(u8, encoded[0..2], "Ed"))
        return error.InvalidMinisignPublicKey;

    return encoded;
}

fn decodeFixed(comptime N: usize, encoded: []const u8) ![N]u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
        return error.InvalidMinisignSignature;
    if (decoded_len != N) {
        return error.InvalidMinisignSignature;
    }

    var decoded: [N]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, encoded) catch
        return error.InvalidMinisignSignature;

    return decoded;
}

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

test "parse padded Minisign signature" {
    const signature =
        "untrusted comment: signature from minisign secret key\n" ++
        "RUSGOq2NVecA2RvK7di8o+6kjPUxmGqO8a9ejbbiN7K/8YeT0lKSdmDVOv2wjd+A0XwQzLKPcdWo66SWTDXJQPEeUUQqQbIWqwo=\n" ++
        "trusted comment: timestamp:1785685616\tfile:zig-x86_64-linux-0.17.0-dev.1525+91c6d8a09.tar.xz\thashed\n" ++
        "wEAYx4KI6j0napCIbeb4i/2QDBs2Ebfs45X9jYGRd8JwrSBp8Q8sWvpgTw83lsieJ9QUf5IxCJw9Gk16mn41CQ==\n";

    const parsed = try parseSignature(signature);
    try std.testing.expectEqualStrings(
        "timestamp:1785685616\tfile:zig-x86_64-linux-0.17.0-dev.1525+91c6d8a09.tar.xz\thashed",
        parsed.trusted_comment,
    );

    const signature_bytes = parsed.signature.toBytes();
    var verifier = try parsed.global_signature.verifier(try zigPublicKey());
    verifier.update(&signature_bytes);
    verifier.update(parsed.trusted_comment);
    try verifier.verify();
}
