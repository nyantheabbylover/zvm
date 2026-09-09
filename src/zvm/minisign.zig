const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Io = std.Io;

//

const zig_public_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";
const zls_public_key = "RWR+9B91GBZ0zOjh6Lr17+zKf5BoSuFvrx2xSeDE57uIYvnKBGmMjOex";

pub const TrustedKey = enum {
    zig,
    zls,
};

const ParsedSignature = struct {
    signature: Ed25519.Signature,
    trusted_comment: []const u8,
    global_signature: Ed25519.Signature,
};

pub fn verifyFile(
    io: Io,
    path: []const u8,
    signature_text: []const u8,
    trusted_key: TrustedKey,
) !void {
    const parsed = try parseSignature(signature_text, trusted_key);

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
    try verifyDigest(parsed, &digest, try publicKey(trusted_key));
}

fn parseSignature(text: []const u8, trusted_key: TrustedKey) !ParsedSignature {
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

    const key = try publicKeyBytes(trusted_key);
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

fn publicKey(trusted_key: TrustedKey) !Ed25519.PublicKey {
    const encoded = try publicKeyBytes(trusted_key);

    return Ed25519.PublicKey.fromBytes(encoded[10..42].*) catch
        return error.InvalidMinisignPublicKey;
}

fn publicKeyBytes(trusted_key: TrustedKey) ![42]u8 {
    const encoded_key = switch (trusted_key) {
        .zig => zig_public_key,
        .zls => zls_public_key,
    };
    const encoded = try decodeFixed(42, encoded_key);
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

//

test "pinned Zig Minisign public key is valid" {
    _ = try publicKey(.zig);
}

test "pinned ZLS Minisign public key is valid" {
    _ = try publicKey(.zls);
}

test "parseSignature rejects malformed signatures" {
    try std.testing.expectError(
        error.InvalidMinisignSignature,
        parseSignature("definitely not a signature", .zig),
    );
}

test "parseSignature accepts padded CRLF Minisign structure" {
    const key = try publicKeyBytes(.zig);
    var signature_bytes: [74]u8 = @splat(0);
    @memcpy(signature_bytes[0..2], "ED");
    @memcpy(signature_bytes[2..10], key[2..10]);
    const global_bytes: [64]u8 = @splat(0);

    var signature_encoded: [std.base64.standard.Encoder.calcSize(signature_bytes.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&signature_encoded, &signature_bytes);
    var global_encoded: [std.base64.standard.Encoder.calcSize(global_bytes.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&global_encoded, &global_bytes);

    const text = try std.fmt.allocPrint(
        std.testing.allocator,
        "untrusted comment: test\r\n{s}\r\ntrusted comment: timestamp:0\r\n{s}\r\n",
        .{ &signature_encoded, &global_encoded },
    );
    defer std.testing.allocator.free(text);

    const parsed = try parseSignature(text, .zig);
    try std.testing.expectEqualStrings("timestamp:0", parsed.trusted_comment);
}

test "verifyDigest validates both Minisign signatures" {
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{1} ** Ed25519.KeyPair.seed_length);
    const digest = "archive digest";
    const trusted_comment = "timestamp:0";
    const archive_signature = try key_pair.sign(digest, null);
    const archive_signature_bytes = archive_signature.toBytes();

    var global_message: [archive_signature_bytes.len + trusted_comment.len]u8 = undefined;
    @memcpy(global_message[0..archive_signature_bytes.len], &archive_signature_bytes);
    @memcpy(global_message[archive_signature_bytes.len..], trusted_comment);
    const global_signature = try key_pair.sign(&global_message, null);

    const parsed = ParsedSignature{
        .signature = archive_signature,
        .trusted_comment = trusted_comment,
        .global_signature = global_signature,
    };
    try verifyDigest(parsed, digest, key_pair.public_key);
    try std.testing.expectError(
        error.InvalidArchiveSignature,
        verifyDigest(parsed, "different archive digest", key_pair.public_key),
    );

    var invalid_global_signature_bytes = global_signature.toBytes();
    invalid_global_signature_bytes[0] ^= 1;
    const invalid_global = ParsedSignature{
        .signature = archive_signature,
        .trusted_comment = trusted_comment,
        .global_signature = Ed25519.Signature.fromBytes(invalid_global_signature_bytes),
    };
    try std.testing.expectError(
        error.InvalidGlobalSignature,
        verifyDigest(invalid_global, digest, key_pair.public_key),
    );
}

test "parse padded Minisign signature" {
    const signature =
        "untrusted comment: signature from minisign secret key\n" ++
        "RUSGOq2NVecA2RvK7di8o+6kjPUxmGqO8a9ejbbiN7K/8YeT0lKSdmDVOv2wjd+A0XwQzLKPcdWo66SWTDXJQPEeUUQqQbIWqwo=\n" ++
        "trusted comment: timestamp:1785685616\tfile:zig-x86_64-linux-0.17.0-dev.1525+91c6d8a09.tar.xz\thashed\n" ++
        "wEAYx4KI6j0napCIbeb4i/2QDBs2Ebfs45X9jYGRd8JwrSBp8Q8sWvpgTw83lsieJ9QUf5IxCJw9Gk16mn41CQ==\n";

    const parsed = try parseSignature(signature, .zig);
    try std.testing.expectEqualStrings(
        "timestamp:1785685616\tfile:zig-x86_64-linux-0.17.0-dev.1525+91c6d8a09.tar.xz\thashed",
        parsed.trusted_comment,
    );

    const signature_bytes = parsed.signature.toBytes();
    var verifier = try parsed.global_signature.verifier(try publicKey(.zig));
    verifier.update(&signature_bytes);
    verifier.update(parsed.trusted_comment);
    try verifier.verify();
}

test "parse ZLS Minisign signature with the pinned key" {
    const signature =
        "untrusted comment: signature from minisign secret key\n" ++
        "RUR+9B91GBZ0zKpvKRpfuRrIxHeJCQKmnsr3BbIAystMje6/MTrBHAyUJyS8ckxj2CLd2JGTACJUKozvXIrCAF8sJ0nTJyokJA4=\n" ++
        "trusted comment: timestamp:1776369627\tfile:zls-x86_64-linux-0.16.0.tar.xz\thashed\n" ++
        "d4PlpQRAzVVxHmrtLU7xlTB+Lbpe6HhOF/q4FCauoHPguaM4U1RwjB8JV4mXmsOTnPjD+CTrFnkUZXN3h1w/CQ==\n";

    const parsed = try parseSignature(signature, .zls);
    try std.testing.expectEqualStrings(
        "timestamp:1776369627\tfile:zls-x86_64-linux-0.16.0.tar.xz\thashed",
        parsed.trusted_comment,
    );
    try std.testing.expectError(
        error.UnknownMinisignKey,
        parseSignature(signature, .zig),
    );
}
