import Foundation

struct HEVCParameterSets: Equatable, Sendable {
    let vps: Data
    let sps: Data
    let pps: Data
}

struct ParsedHEVCAccessUnit: Equatable, Sendable {
    let vps: Data?
    let sps: Data?
    let pps: Data?
    let lengthPrefixedPictureData: Data?
    let containsIDR: Bool
}

enum HEVCAnnexBParser {
    private static let vpsType: UInt8 = 32
    private static let spsType: UInt8 = 33
    private static let ppsType: UInt8 = 34
    private static let audType: UInt8 = 35
    private static let eosType: UInt8 = 36
    private static let eobType: UInt8 = 37
    private static let fillerType: UInt8 = 38
    private static let idrWithRADLType: UInt8 = 19
    private static let idrNoLeadingPicturesType: UInt8 = 20

    static func parse(_ data: Data) throws -> ParsedHEVCAccessUnit {
        let bytes = [UInt8](data)
        let startCodes = findStartCodes(in: bytes)
        guard startCodes.isEmpty == false else {
            throw HEVCDecodeFailure.malformedAnnexB
        }

        var vps: Data?
        var sps: Data?
        var pps: Data?
        var pictureNALUnits: [Data] = []
        var containsIDR = false

        for (offset, startCode) in startCodes.enumerated() {
            let nalStart = startCode.index + startCode.length
            let nalEnd = offset + 1 < startCodes.count
                ? startCodes[offset + 1].index
                : bytes.count
            guard nalStart < nalEnd else { continue }

            let nalUnit = Data(bytes[nalStart..<nalEnd])
            guard nalUnit.count >= 2 else { continue }
            let type = (nalUnit[nalUnit.startIndex] >> 1) & 0x3f

            switch type {
            case vpsType:
                vps = nalUnit
            case spsType:
                sps = nalUnit
            case ppsType:
                pps = nalUnit
            case audType, eosType, eobType, fillerType:
                continue
            default:
                pictureNALUnits.append(nalUnit)
                containsIDR = containsIDR
                    || type == idrWithRADLType
                    || type == idrNoLeadingPicturesType
            }
        }

        guard vps != nil || sps != nil || pps != nil || pictureNALUnits.isEmpty == false else {
            throw HEVCDecodeFailure.malformedAnnexB
        }

        var lengthPrefixedPictureData: Data?
        if pictureNALUnits.isEmpty == false {
            var converted = Data()
            let capacity = pictureNALUnits.reduce(into: 0) { result, nalUnit in
                result += MemoryLayout<UInt32>.size + nalUnit.count
            }
            converted.reserveCapacity(capacity)
            for nalUnit in pictureNALUnits {
                guard let length = UInt32(exactly: nalUnit.count) else {
                    throw HEVCDecodeFailure.malformedAnnexB
                }
                var bigEndianLength = length.bigEndian
                withUnsafeBytes(of: &bigEndianLength) { converted.append(contentsOf: $0) }
                converted.append(nalUnit)
            }
            lengthPrefixedPictureData = converted
        }

        return ParsedHEVCAccessUnit(
            vps: vps,
            sps: sps,
            pps: pps,
            lengthPrefixedPictureData: lengthPrefixedPictureData,
            containsIDR: containsIDR
        )
    }

    private static func findStartCodes(
        in bytes: [UInt8]
    ) -> [(index: Int, length: Int)] {
        guard bytes.count >= 3 else { return [] }
        var result: [(index: Int, length: Int)] = []
        var index = 0

        while index + 2 < bytes.count {
            guard bytes[index] == 0, bytes[index + 1] == 0 else {
                index += 1
                continue
            }
            if index + 3 < bytes.count,
               bytes[index + 2] == 0,
               bytes[index + 3] == 1 {
                result.append((index, 4))
                index += 4
            } else if bytes[index + 2] == 1 {
                result.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        return result
    }
}
