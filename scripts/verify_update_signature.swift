// Checks an update's EdDSA signature against the public key, as installed apps do.
// Usage: swift scripts/verify_update_signature.swift <base64 public key> <base64 signature> <file>
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let file = FileManager.default.contents(atPath: arguments[3]) else {
    FileHandle.standardError.write(Data("usage: verify_update_signature <public key> <signature> <file>\n".utf8))
    exit(2)
}
guard key.isValidSignature(signature, for: file) else {
    FileHandle.standardError.write(Data("The signature does not match the public key.\n".utf8))
    exit(1)
}
print("EdDSA signature valid for the public key.")
