@preconcurrency import CommonCrypto
@preconcurrency import Foundation

// MARK: - AES-256-CBC Accessibility Attribute Decryption
// These constants are AES-encrypted to prevent exposure via `strings` on the binary.

// Key split into 4 parts — same key as CloudProvider
private let _kp0: [UInt8] = [0x7D, 0x90, 0x2B, 0x95, 0x1A, 0x4D, 0xED, 0x1F, 0x01, 0xF6, 0x0F, 0x19, 0x9F, 0xDB, 0x4F, 0x45, 0x16, 0x9D, 0x02, 0x24, 0xCA, 0x10, 0x49, 0xD6, 0xF8, 0x09, 0x0C, 0x32, 0x15, 0x9E, 0xEB, 0x66]
private let _kp1: [UInt8] = [0xB2, 0xA0, 0xD4, 0x3A, 0x64, 0xF6, 0xBA, 0x61, 0x50, 0x4E, 0x0A, 0x00, 0x21, 0x75, 0x05, 0x36, 0xBD, 0x69, 0xF3, 0xB4, 0x07, 0x24, 0x56, 0xF7, 0x2F, 0xD1, 0x93, 0x11, 0x08, 0x3D, 0x41, 0xB4]
private let _kp2: [UInt8] = [0xB6, 0x27, 0x28, 0x12, 0x84, 0x94, 0xD5, 0x62, 0x6A, 0xDF, 0x20, 0xBF, 0xD3, 0x28, 0x42, 0x33, 0xC0, 0xAE, 0xF7, 0x15, 0x53, 0xC2, 0x6B, 0xF7, 0x64, 0xD8, 0x4E, 0x57, 0x6F, 0xB4, 0x12, 0x8A]
private let _kp3: [UInt8] = [0xE2, 0x1C, 0xBC, 0x9D, 0x63, 0x0B, 0x75, 0x66, 0x98, 0xC4, 0xCB, 0x08, 0x5A, 0x00, 0x9E, 0x28, 0xB7, 0x32, 0xE8, 0x02, 0x3F, 0x77, 0xEB, 0xC5, 0x26, 0x94, 0x29, 0x70, 0x26, 0xBB, 0x12, 0x52]
private func _axKey() -> Data { Data((0..<32).map { _kp0[$0] ^ _kp1[$0] ^ _kp2[$0] ^ _kp3[$0] }) }

private func _ax(_ b64: String) -> CFString {
    guard let data = Data(base64Encoded: b64), data.count > kCCBlockSizeAES128 else { return "" as CFString }
    let iv = data.prefix(kCCBlockSizeAES128)
    let ciphertext = data.suffix(from: kCCBlockSizeAES128)
    let key = _axKey()
    let outLen = ciphertext.count + kCCBlockSizeAES128
    var out = Data(count: outLen)
    var written = 0
    let status = key.withUnsafeBytes { k in
        iv.withUnsafeBytes { i in
            ciphertext.withUnsafeBytes { c in
                out.withUnsafeMutableBytes { o in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, kCCKeySizeAES256, i.baseAddress,
                            c.baseAddress, ciphertext.count, o.baseAddress, outLen, &written)
                }
            }
        }
    }
    guard status == kCCSuccess else { return "" as CFString }
    return (String(data: out.prefix(written), encoding: .utf8) ?? "") as CFString
}

// Parameterized attributes
nonisolated(unsafe) let axBoundsForRange = _ax("HVzGqedx4CY+sRFeH2l27snAp3zQrW9/dDB9+7HmuLsNQno0ftmXmpzMlIDz9IhB")
nonisolated(unsafe) let axAttributedStringForRange = _ax("LzQ73DQTBXePJLPhQUBS2HrNIHb7CSTFwTcqeU4lAt1bUr33f1UICXf3VvejQjMv")
nonisolated(unsafe) let axTextMarkerForIndex = _ax("mNKJgZTi7LrQgPUb4EoFB8LORGCr0Qxz9hFtKdcTVkKxXPvEv9fKM+qL2y/4Wswe")
nonisolated(unsafe) let axIndexForTextMarker = _ax("B8TiBuv+kGKiYcO2TBoVdujMNZ15NjkMHtWhniifyU2eUnG2ZQvLHW3L7EMPzqA+")
nonisolated(unsafe) let axTextMarkerRangeForUnorderedTextMarkers = _ax("y7ul45OFNoXK2mQjIm817BjviWnX5jJXX/d7n23N0tPxG7nVtYCP2xRxf+9KCb/nSDH4IfcKAjcUvFrBeK7sSQ==")
nonisolated(unsafe) let axBoundsForTextMarkerRange = _ax("GwuTZvUwRvDOGvPWMn9Nv3oLIEiw/Nlrb8anzjbVEBc4lki/y2hoOeP8V6Zo1R3n")
nonisolated(unsafe) let axSelectedTextMarkerRange = _ax("2o3TyF7sSl947r/2HMo5KQxbMlCQVffQAk4+hgGgqSObFpK9J6VVfLIsd+HUjJCW")
nonisolated(unsafe) let axAttributedStringForTextMarkerRange = _ax("VxnoBJ++iVZCCD9lHZ4F9tQ2N3g5JGVyutf/e6IWfv8DPp47BlhXmBui5NvMskBo1jgiA/imqKrMs/m4XBFu5Q==")
nonisolated(unsafe) let axStartTextMarker = _ax("EPLi8WkrJ6xJhxWMaGDtC8XoiQySiYlDwqx5PtPgIsDRvBj1G+CxWP9pLYLA+jdj")
nonisolated(unsafe) let axEndTextMarker = _ax("tneYFg0fbOY/o89NfBC2eZvRmMK+jBI4Spiia1lD1W8=")
nonisolated(unsafe) let axLineForIndex = _ax("Kt+sk8q3JZk8nMYSJio+qpsJHmt7yXacE7UjOYTHON8=")
nonisolated(unsafe) let axRangeForLine = _ax("RSo/A3eKFSjOSQZcAjlxJ/DDMQsBOMN+HF+sybjJp1Q=")
nonisolated(unsafe) let axStringForRange = _ax("4n1xltww9W1KeTHRDPXloXynlfeW4T5hCRE3Evm7X/gDMUjmgj/MlJntxFufZRDy")

// Standard attributes
nonisolated(unsafe) let axInsertionPointLineNumber = _ax("G6Rm9x9aVPCfQat3yMxkB86nlTkwU4GOnXkc0LAHpIHIEr4O4GDEr8KqonrzD1a7")
nonisolated(unsafe) let axManualAccessibility = _ax("S+2GqOsJAb75OQgsmmCdJbNCd2iY/BrQmTrNB+jvT3PPMnPScjnpiQH/hJ07W+K/")
nonisolated(unsafe) let axEnhancedUserInterface = _ax("IZ7PnMwVc3fpiWF771yzAcdEoR7RbY81VdrQKW1HSGrSfb526thj9BvtYOnrHRjA")
nonisolated(unsafe) let axDOMClassList = _ax("cwyDTnZdT9mnCDf478CexsW4jsAvgy7AChaysfdQx2w=")

// Framework attributes (replacing kAX* constants)
nonisolated(unsafe) let axFocusedApplication = _ax("vMHXU5eC1EykhuHwwINnuBdzXjx68TFFNga4gex10GW/uaL0iaW7HAKPLpUDwvH1")
nonisolated(unsafe) let axFocusedWindow = _ax("IqQVlOVLQOARW7cP+9pXoVmOZlAsE7UfHROY+gnTvX4=")
nonisolated(unsafe) let axTitle = _ax("0/pJKldt7DCF8WFn7RiRuXCjyVf2Xxdc7GBgyJg9aSI=")
nonisolated(unsafe) let axFocusedUIElement = _ax("sbfuEqrAxC7MR8e4inHH+xVfZxWEejq5Mkli7CZTvtMMjaG+dioxcrerENQJ2eqx")
nonisolated(unsafe) let axRole = _ax("JGkKZ/XVI31I1WeAfoFz+XPv/7GPWa982IurkgH4Lsw=")
nonisolated(unsafe) let axTextField = _ax("pjZ147mBqiWeJ/C7e3Y60RdTzyiVNa/OgKsOxGv9oYc=")
nonisolated(unsafe) let axTextArea = _ax("YF9XkOgf+JaUPUPU8qzCIsDSZSgFpZK3uo8NZ2mgANY=")
nonisolated(unsafe) let axComboBox = _ax("tcNJA5YKHTfYNv/7lk+wGidTMn8ApfZz1jPuAViT280=")
nonisolated(unsafe) let axWebArea = _ax("KXHuygiDYOHCp++JAOa26KP/pY+AKj2KejUUlHIub9A=")
nonisolated(unsafe) let axSubrole = _ax("Cdd2kf+uc2cVhWRZvX6DWm/5cAQAN6GAWtgzCkJASH0=")
nonisolated(unsafe) let axSecureTextField = _ax("AFlzP7gtvTL3K3GWgNPWIy0Fnu/ngQF6sl16onBuvHPL8nYw8KZUUQk1mzBp1zgv")
nonisolated(unsafe) let axSearchField = _ax("Y4xoRZ2gy5KtvbL57cJaQFufaCggj5M5rJzpWvCE/nU=")
nonisolated(unsafe) let axValue = _ax("jloxvPPOyj/fiKVz9Pz2e3ZMy9Pu9hAbdQvIDN6roX8=")
nonisolated(unsafe) let axSelectedTextRange = _ax("s64Jv4rQgPoizB9feOPCQD5BMLkXQVL6RQJF4MSlN495+2RHGgfpdZPxW+e4fpgv")
nonisolated(unsafe) let axNumberOfCharacters = _ax("rOHzzW6cHBDoIMI9BeaB4wTCOB4WI/mG9rOzIkzmBHVGh38wjWVSbxKLhfjkUe4b")
nonisolated(unsafe) let axPosition = _ax("aXbzcIwH8Y84qLX6/SDRMGMW98s7jW3eeM13sf4B4TE=")
nonisolated(unsafe) let axSize = _ax("kwzClBCTAVL65rGycZvFC6zBNeOdHKG0nipB/O0Y+u8=")
nonisolated(unsafe) let axChildren = _ax("G4Yy08F/2daWSTaQPCuQ4FKYpzlFu9/gJtLF0dXhRhY=")
nonisolated(unsafe) let axStaticText = _ax("294GGfWg9aJxoDHGZ2t92Gii6IKBMOXzE8wjZ4rUf5k=")
nonisolated(unsafe) let axParent = _ax("zCfzyoBaxNdTaP3TDQ3UtryobRVlEbbF81BCjwRvVZU=")
nonisolated(unsafe) let axSelectedText = _ax("aEeAL/N0I/CjgdoiHPjTuPukZts42SoBHhIv+LTIc30=")
nonisolated(unsafe) let axFocusedUIElementChanged = _ax("K/0R8Vhzy13bwtrMyE5RngVuRNYbak9WiheGWklp+5qM0H8JTl+YTFGplKRzEsSO")
nonisolated(unsafe) let axFontKey = _ax("QK2Wb9tN+DXJPMTePeFoTgOhV0iQXEIpr16SBzfQfCg=")
nonisolated(unsafe) let axFontSizeKey = _ax("zley4oaEl/+BVM6RsCovoAQTn01P85+YMtg0wk+BX/A=")
nonisolated(unsafe) let axFontNameKey = _ax("dAUGLXKmlTxRS4ER1xPZPfSP4vqpb6yx/RCtbCA12a4=")
