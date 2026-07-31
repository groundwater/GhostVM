import Crypto
import Foundation
import Security
import X509

struct GhostFileTLSIdentity {
    let networkIdentity: sec_identity_t
    let publicKeyPin: String
    let certificatePEM: String
    let privateKeyPEM: String

    static func make() throws -> Self {
        var keyError: Unmanaged<CFError>?
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let secKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &keyError) else {
            throw IdentityError.security(keyError?.takeRetainedValue())
        }

        var exportError: Unmanaged<CFError>?
        guard let externalKey = SecKeyCopyExternalRepresentation(secKey, &exportError) as Data? else {
            throw IdentityError.security(exportError?.takeRetainedValue())
        }
        let signingKey = try P256.Signing.PrivateKey(x963Representation: externalKey)
        let name = try DistinguishedName {
            OrganizationName("GhostVM")
            CommonName("GhostFile Local Share")
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(signingKey.publicKey),
            notValidBefore: Date().addingTimeInterval(-300),
            notValidAfter: Date().addingTimeInterval(365 * 24 * 60 * 60),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: Certificate.PrivateKey(signingKey)
        )
        let secCertificate = try SecCertificate.makeWithCertificate(certificate)
        guard let secIdentity = SecIdentityCreate(nil, secCertificate, secKey),
              let networkIdentity = sec_identity_create(secIdentity) else {
            throw IdentityError.couldNotCreateIdentity
        }

        // GhostHTTP3 exposes quiche's DER leaf certificate directly. Pin that
        // exact certificate for the lifetime of this ephemeral share.
        let certificateDER = try certificate.serializeAsPEM().derBytes
        let digest = SHA256.hash(data: certificateDER)
        let pin = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self(
            networkIdentity: networkIdentity,
            publicKeyPin: pin,
            certificatePEM: try certificate.serializeAsPEM().pemString,
            privateKeyPEM: try Certificate.PrivateKey(signingKey).serializeAsPEM().pemString
        )
    }

    private enum IdentityError: LocalizedError {
        case security(CFError?)
        case couldNotCreateIdentity

        var errorDescription: String? {
            switch self {
            case .security(let error):
                return error.map { CFErrorCopyDescription($0) as String } ?? "Unable to create the GhostFile TLS key"
            case .couldNotCreateIdentity:
                return "Unable to create the GhostFile TLS identity"
            }
        }
    }
}
