import CryptoKit
import Foundation

/// The SHA git gives a file, so a local file compares directly with GitHub's tree.
public enum GitBlob {
    public static func sha(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
