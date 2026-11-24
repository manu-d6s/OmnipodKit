//
//  O5PodIdentityTests.swift
//  OmniTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CryptoKit
import XCTest
@testable import OmnipodKit

class O5PodIdentityTests: XCTestCase {

    /// A certificate from a pod served by the LoopKit/pod simulator, signed by
    /// the CA that repository publishes.
    private let simulatedPodCertificate = Data(hexadecimalString: [
        "3082019030820137a0030201020209008b162d93578006cb300a06082a8648ce",
        "3d040302303331163014060355040a130d706f642073696d756c61746f723119",
        "301706035504031310706f642073696d756c61746f72204341301e170d323631",
        "3032383030303231305a170d3336313032353031303231305a30343116301406",
        "0355040a130d706f642073696d756c61746f72311a301806035504031311706f",
        "642073696d756c61746f7220706f643059301306072a8648ce3d020106082a86",
        "48ce3d03010703420004cfec6c026779c9b5728a748580e7af8709c3e408b7e0",
        "69963e38f276756005e92b791e23d4099075ee3dc02bceae85b8d1d1489f8c98",
        "71f39e3f1aee2ead7fd1a3333031300e0603551d0f0101ff040403020780301f",
        "0603551d2304183016801470d1e1f42826b71f50905e2a54bf54f78c984edd30",
        "0a06082a8648ce3d04030203470030440220442ec2c82f24763a413b2cb4d49e",
        "0dbbe18cf58b475f352c3f24151d9e52186f022043ecdc41033fa354a21cb557",
        "dd0f180513e9c63235a991988d10ac6809f0fae0"
    ].joined())!

    /// A pod the simulator served must be recognised as simulated, not merely
    /// left unplaced. That is the whole point of the simulator publishing a
    /// fixed CA.
    func testSimulatedPodIsRecognised() {
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: simulatedPodCertificate), .simulated)
    }

    /// Insulet's intermediate did not sign the simulator's pods, so a
    /// simulated pod must never read as genuine.
    func testSimulatedPodIsNotGenuine() {
        let signed = SignedCertificate(der: simulatedPodCertificate)
        XCTAssertNotNil(signed)
        for key in O5PodIdentity.insuletPodAnchorKeys {
            XCTAssertFalse(signed!.isSigned(byPublicKey: key))
        }
    }

    /// Anything we cannot place is unverified, which asks the user before
    /// pairing. Rubbish must not crash or read as either anchor.
    func testUnplaceableCertificatesAreUnverified() {
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: Data()), .unverified)
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: Data([0x30, 0x82, 0xff, 0xff])), .unverified)
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: Data(repeating: 0x41, count: 400)), .unverified)
        // A truncated but otherwise well-formed certificate.
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: simulatedPodCertificate.prefix(120)), .unverified)
    }

    /// The signature must actually be checked: flipping a byte of the signed
    /// body has to stop it verifying.
    func testATamperedCertificateIsNotRecognised() {
        var tampered = simulatedPodCertificate
        // Somewhere inside the TBSCertificate, past its header.
        tampered[60] = tampered[60] ^ 0xff
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: tampered), .unverified)
    }

    /// The DER split has to find the signed body and the signature. A
    /// certificate is a SEQUENCE of TBSCertificate, the algorithm, and the
    /// signature as a BIT STRING.
    func testSignedCertificateSplitsTheDER() throws {
        let signed = try XCTUnwrap(SignedCertificate(der: simulatedPodCertificate))
        XCTAssertEqual(signed.tbs.first, 0x30, "the signed body is a SEQUENCE")
        XCTAssertGreaterThan(signed.tbs.count, 100)
        XCTAssertLessThan(signed.tbs.count, simulatedPodCertificate.count)
        XCTAssertEqual(signed.signature.first, 0x30, "an ECDSA signature is a DER SEQUENCE of r and s")
        XCTAssertGreaterThan(signed.signature.count, 60)
    }

    /// The pinned anchors must be what they claim to be: valid P-256 public
    /// keys (a mistyped hex digit would leave every real pod unrecognised),
    /// and a parseable certificate.
    func testAnchorsAreWellFormed() {
        XCTAssertFalse(O5PodIdentity.insuletPodAnchorKeys.isEmpty)
        for key in O5PodIdentity.insuletPodAnchorKeys {
            XCTAssertEqual(key.count, 64, "a raw P-256 key is x then y")
            XCTAssertNoThrow(try P256.Signing.PublicKey(rawRepresentation: key), "not a point on P-256")
        }
        XCTAssertNotNil(O5CertificateStore.extractP256PublicKey(fromDERCert: O5PodIdentity.simulatorAnchorCertificate))
    }

    // MARK: - Where the pinned key comes from

    /// The public key of CN=INS00PG1, Insulet's root, which issued the pod intermediate.
    private let insuletRootKey = Data(hexadecimalString: [
        "8a16b9ea0025860d06e3a8412ced307eae3da04ca73dbd6e85c8ea3e9070a607",
        "2f749ff6662c8b0702daf1974562c634a7e4da9324ceee75a22e27089d2e61df"
    ].joined())!

    /// Insulet's pod intermediate, CN=INS01PG1, issued by CN=INS00PG1, as a real
    /// Omnipod 5 showed it in SPS2.1. It is the same for every pod.
    private let insuletIntermediateCertificate = Data(hexadecimalString: [
        "308202753082021ca00302010202147bd7145fb071139dce09018aa768cf08b7",
        "2110d3300a06082a8648ce3d04030230253110300e060355040a0c07496e7375",
        "6c65743111300f06035504030c08494e533030504731301e170d323130333032",
        "3230343430375a170d3336303232373230343430365a30253110300e06035504",
        "0a0c07496e73756c65743111300f06035504030c08494e533031504731305930",
        "1306072a8648ce3d020106082a8648ce3d03010703420004ad2f3b7cc5b5971b",
        "ea582dff282e08421416d92e2380dbb45802944138cde023c5480d43ce04fda1",
        "0b4980139a400903f581a3ef8a67186d719a79dc5492f441a382012830820124",
        "300f0603551d130101ff040530030101ff301f0603551d23041830168014e104",
        "6965d31c40730ac802fcc1e600ac51485e293081c00603551d1f0481b83081b5",
        "3081b2a08184a08181867f687474703a2f2f69737375696e672e70726f642d6f",
        "6d6e69706f64636c6f75642e75732e70726f642e736161732e7072696d656b65",
        "792e636f6d2f656a6263612f7075626c69637765622f63726c732f7365617263",
        "682e6367693f734b4944486173683d345152705a644d6351484d4b79414c3877",
        "6559417246464958696ba229a42730253111300f06035504030c08494e533030",
        "5047313110300e060355040a0c07496e73756c6574301d0603551d0e04160414",
        "1fb8f8b7d6c5ac2031fffcac3e61cb9355584793300e0603551d0f0101ff0404",
        "03020186300a06082a8648ce3d04030203470030440220031af86068fb377172",
        "5f364c272ac83d4fd7902ff189ab0e647b6affd079536d022073fceb7be1f2b2",
        "0134f93f74bf427d243a9e43f25d1f96373edb828ed0f1a4c0"
    ].joined())!

    /// The pinned key is that of Insulet's pod intermediate, and the intermediate
    /// validates under Insulet's root.
    func testThePinnedKeyIsInsuletsPodIntermediate() throws {
        let intermediate = try XCTUnwrap(SignedCertificate(der: insuletIntermediateCertificate))
        XCTAssertTrue(intermediate.isSigned(byPublicKey: insuletRootKey))
        let key = try XCTUnwrap(O5CertificateStore.extractP256PublicKey(fromDERCert: intermediate.tbs))
        XCTAssertTrue(O5PodIdentity.insuletPodAnchorKeys.contains(key))
    }

    // MARK: - The pod role

    /// An Insulet certificate issued by CN=INS01PG1 for driver updates, not for a
    /// pod: its role is devicetype:POD_OTA_leaf.
    private let insuletLeafCertificate = Data(hexadecimalString: [
        "30820327308202cca00302010202144ff54908363e24c08022fe36bb40b7b014",
        "631fac300a06082a8648ce3d04030230253110300e060355040a0c07496e7375",
        "6c65743111300f06035504030c08494e533031504731301e170d323630343130",
        "3137353635345a170d3239303430393137353635335a304c3117301506035504",
        "030c0e506f644f74614c656166436572743110300e060355040a0c07496e7375",
        "6c657431123010060355040b0c09417574685573657273310b30090603550406",
        "130255533059301306072a8648ce3d020106082a8648ce3d030107034200041f",
        "67e15b5b9cf6be236d05c7f269a06e9562baf33585eac70630a04a051b786694",
        "776b723b3dc2ec2ed9acad6f0691cc686f2024c575c99453df92238256197ca3",
        "8201b1308201ad300c0603551d130101ff04023000301f0603551d2304183016",
        "80141fb8f8b7d6c5ac2031fffcac3e61cb9355584793307206082b0601050507",
        "010104663064306206082b060105050730018656687474703a2f2f6973737569",
        "6e672e70726f642d6f6d6e69706f64636c6f75642e75732e70726f642e736161",
        "732e7072696d656b65792e636f6d2f656a6263612f7075626c69637765622f73",
        "74617475732f6f63737030220603551d11041b30198617646576696365747970",
        "653a504f445f4f54415f6c656166301d0603551d250416301406082b06010505",
        "07030206082b060105050703013081950603551d1f04818d30818a308187a081",
        "84a08181867f687474703a2f2f69737375696e672e70726f642d6f6d6e69706f",
        "64636c6f75642e75732e70726f642e736161732e7072696d656b65792e636f6d",
        "2f656a6263612f7075626c69637765622f63726c732f7365617263682e636769",
        "3f734b4944486173683d48376a3474396246724341782f2f7973506d484c6b31",
        "565952354d301d0603551d0e04160414230f41b660290a37acee771be893346a",
        "5ec9de13300e0603551d0f0101ff0404030205a0300a06082a8648ce3d040302",
        "03490030460221008ee0232739157e1061abd1990a722019980625cb59f3af8b",
        "ca8764b3481c7da2022100f9faa91fd661cf2891c2d618af04c3f847b899e785",
        "ebec5d95f669d5ba4ca438"
    ].joined())!

    /// A certificate signed by the pinned intermediate is still not a pod's
    /// unless it names the pod role.
    func testAnInsuletCertificateWithoutThePodRoleIsNotGenuine() {
        let signed = SignedCertificate(der: insuletLeafCertificate)
        XCTAssertTrue(O5PodIdentity.insuletPodAnchorKeys.contains(where: { signed!.isSigned(byPublicKey: $0) }))
        XCTAssertEqual(signed?.subjectAlternativeNameURIs, ["devicetype:POD_OTA_leaf"])
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: insuletLeafCertificate), .unverified)
    }

    /// A test intermediate's key, standing in for a pinned anchor, and
    /// certificates it signed with different roles. The private keys were discarded.
    private let testAnchorKey = Data(hexadecimalString: [
        "e4aa3d6fafc32cccea3638bbdbc2569eebe3e6ef76f40f1dfd962b0fdfd0dafb",
        "a29b3694818ba302f1fb61bed3fecb293c50eef1097f736c9557a1c8a518c38b"
    ].joined())!
    private let testPodCertificate = Data(hexadecimalString: [
        "308201bb30820161a003020102020104300a06082a8648ce3d040302302f310d",
        "300b060355040a0c0474657374311e301c06035504030c157465737420706f64",
        "20696e7465726d656469617465301e170d3236313132343134353930385a170d",
        "3336313132313134353930385a3022310d300b060355040a0c04746573743111",
        "300f06035504030c087465737420706f643059301306072a8648ce3d02010608",
        "2a8648ce3d0301070342000489216381ec78c300e7757dd8fbd1b640d42d1563",
        "a11fe9210fc0e6b4ae9ad9c0a746e903622c9d7a5d7821bf7c4becb697776d67",
        "17ece5b1f9b9173ff80db3e1a37b3079300c0603551d130101ff04023000300e",
        "0603551d0f0101ff040403020780301d0603551d0e04160414c962935b9b9ea0",
        "503952594c72a7de8157d77424301f0603551d230418301680142b60d5b00741",
        "4a6e1b9751ee9490aa181d12c74c30190603551d1104123010860e6465766963",
        "65747970653a706f64300a06082a8648ce3d04030203480030450220059ff7af",
        "9f083e3a16e68bbb374d68d60432eda81ff8b39fd58add72e9a8aa47022100d4",
        "e6af18bc37cf118d237743cf082caee4426d7087dc04386c8026856d56dee4"
    ].joined())!
    private let testCertificateWithoutRole = Data(hexadecimalString: [
        "308201b030820155a003020102020105300a06082a8648ce3d040302302f310d",
        "300b060355040a0c0474657374311e301c06035504030c157465737420706f64",
        "20696e7465726d656469617465301e170d3236313132343134353930385a170d",
        "3336313132313134353930385a3031310d300b060355040a0c04746573743120",
        "301e06035504030c177465737420706f6420776974686f7574206120726f6c65",
        "3059301306072a8648ce3d020106082a8648ce3d03010703420004aada71e905",
        "0fd63f42b37382c7fb4a67a62971c0d129684fe1663b283044a8b7940f9eb9fc",
        "2295045d62322b698ba82eedef24c36c46fd687b74fa243ac20736a360305e30",
        "0c0603551d130101ff04023000300e0603551d0f0101ff040403020780301d06",
        "03551d0e0416041495fb3186c609da2587405ece863e5f89d6632f82301f0603",
        "551d230418301680142b60d5b007414a6e1b9751ee9490aa181d12c74c300a06",
        "082a8648ce3d04030203490030460221009f90e5c4ece417557aba0c98e7b074",
        "4a67b9a5d9dc231903825b35dbfd4e93e6022100d66adb87d87bfc822af454ae",
        "0da27908947969eca0d775faf65f61068a1ecd03"
    ].joined())!
    private let testCertificateWithOtherRole = Data(hexadecimalString: [
        "308201d430820179a003020102020106300a06082a8648ce3d040302302f310d",
        "300b060355040a0c0474657374311e301c06035504030c157465737420706f64",
        "20696e7465726d656469617465301e170d3236313132343134353930385a170d",
        "3336313132313134353930385a3034310d300b060355040a0c04746573743123",
        "302106035504030c1a7465737420706f64207769746820616e6f746865722072",
        "6f6c653059301306072a8648ce3d020106082a8648ce3d030107034200048e2a",
        "e9a11fbd8a5ac9dea616f43ef260347f80212bcdd3323a5760f113edf4f8cc1b",
        "bdbafb767bc1d0f47528cb09b5a20822d614dc0b1fb8440617b796d69dcca381",
        "80307e300c0603551d130101ff04023000300e0603551d0f0101ff0404030207",
        "80301d0603551d0e041604143a9c7982ffd248da6ac1e0a0006b704c6fc072be",
        "301f0603551d230418301680142b60d5b007414a6e1b9751ee9490aa181d12c7",
        "4c301e0603551d11041730158613646576696365747970653a706f642d746573",
        "74300a06082a8648ce3d0403020349003046022100caeb823712f86161e5193b",
        "a5a1a7e69cc1d475451cdca598ac3e59eafd2b3610022100ab6cd4cc7086e3b5",
        "8de1f795c1c7b0e280cbaf507572a858b96da90bb1b61cd2"
    ].joined())!
    private let testCertificateWithTwoRoles = Data(hexadecimalString: [
        "308201e930820190a003020102020107300a06082a8648ce3d040302302f310d",
        "300b060355040a0c0474657374311e301c06035504030c157465737420706f64",
        "20696e7465726d656469617465301e170d3236313132343134353930385a170d",
        "3336313132313134353930385a3031310d300b060355040a0c04746573743120",
        "301e06035504030c177465737420706f6420776974682074776f20726f6c6573",
        "3059301306072a8648ce3d020106082a8648ce3d030107034200043b948cfdee",
        "61067b3995fccf17e4268430458941ed5c2eaa7c57603e6de2fe57d41114c6d3",
        "5bf9ad658a0bbee8accf8474f09d4e9ad4559a2fc68bddbf779f0ea3819a3081",
        "97300c0603551d130101ff04023000300e0603551d0f0101ff04040302078030",
        "1d0603551d0e04160414129482f562daf6554f0a328d2a019af970945734301f",
        "0603551d230418301680142b60d5b007414a6e1b9751ee9490aa181d12c74c30",
        "370603551d110430302e860e646576696365747970653a706f64861c64657669",
        "6365747970653a636f6e74726f6c6c6572416e64726f6964300a06082a8648ce",
        "3d040302034700304402203c064efaa7f0d8a31798054bcdf96d4c2b8583d926",
        "853b6a5e8b67af3e7a3ab702205c44a2e670ccbdacf2c8e5d199ec444e740b90",
        "f7b4107a33674b7b3c9f37a109"
    ].joined())!
    /// A pod-role certificate signed by a different intermediate.
    private let testPodCertificateFromAnotherIntermediate = Data(hexadecimalString: [
        "308201dc30820182a003020102020109300a06082a8648ce3d0403023036310d",
        "300b060355040a0c04746573743125302306035504030c1c7465737420636f6e",
        "74726f6c6c657220696e7465726d656469617465301e170d3236313132343134",
        "353930385a170d3336313132313134353930385a303c310d300b060355040a0c",
        "0474657374312b302906035504030c227465737420706f642066726f6d20616e",
        "6f7468657220696e7465726d6564696174653059301306072a8648ce3d020106",
        "082a8648ce3d03010703420004e2a77013c702bfe7c048bfbfb039ca642645d3",
        "cbe37e157cfc25a987dd145870f9c47b3ed082b9f14f39f605fc3601244d0fd7",
        "b2d3051d08e9ce54e9e9ce39b8a37b3079300c0603551d130101ff0402300030",
        "0e0603551d0f0101ff040403020780301d0603551d0e0416041469613813dc72",
        "42579ac96245e9048544e4d30011301f0603551d2304183016801429f2244302",
        "de26799b575f27909b65676129704930190603551d1104123010860e64657669",
        "6365747970653a706f64300a06082a8648ce3d040302034800304502202c3e63",
        "ec4b85627b61f43b405e87d0482958877e38a5c79c3cabc5ed79b31761022100",
        "ca14f8736e9fee75d60c51dd85a2b13dbf487c1fc1324e626b06544ae33190af"
    ].joined())!

    /// A certificate from a pinned anchor with the pod role is genuine.
    func testAPodFromTheAnchorIsGenuine() {
        XCTAssertEqual(SignedCertificate(der: testPodCertificate)?.subjectAlternativeNameURIs, ["devicetype:pod"])
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: testPodCertificate, anchorKeys: [testAnchorKey]), .genuine)
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: testPodCertificate), .unverified)
    }

    /// The pod role must be the certificate's only role, exactly.
    func testOnlyThePodRoleMakesAPod() {
        for certificate in [testCertificateWithoutRole, testCertificateWithOtherRole, testCertificateWithTwoRoles] {
            XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: certificate, anchorKeys: [testAnchorKey]), .unverified)
        }
        XCTAssertEqual(SignedCertificate(der: testCertificateWithoutRole)?.subjectAlternativeNameURIs, [])
        XCTAssertEqual(SignedCertificate(der: testCertificateWithOtherRole)?.subjectAlternativeNameURIs, ["devicetype:pod-test"])
    }

    /// The role does not stand in for the signature: a pod-role certificate
    /// from another intermediate is not genuine.
    func testThePodRoleAloneIsNotEnough() {
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: testPodCertificateFromAnotherIntermediate,
                                                  anchorKeys: [testAnchorKey]), .unverified)
    }

    /// Roles come from the signed body only: bytes after the certificate, or
    /// a certificate with no subject alternative names, add none.
    func testRolesAreReadFromTheSignedBodyOnly() {
        var padded = testCertificateWithoutRole
        padded.append(Data([0x86, 0x0e]) + Data("devicetype:pod".utf8))
        XCTAssertEqual(SignedCertificate(der: padded)?.subjectAlternativeNameURIs, [])
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: padded, anchorKeys: [testAnchorKey]), .unverified)
        XCTAssertEqual(SignedCertificate(der: simulatedPodCertificate)?.subjectAlternativeNameURIs, [])
    }
}
