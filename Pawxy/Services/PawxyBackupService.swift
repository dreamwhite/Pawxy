//
//  PawxyBackupService.swift
//  Pawxy
//

import Foundation

struct PawxyBackupService {
    func export(_ domains: [LocalDomain], to url: URL) throws {
        let data = try encodedBackup(for: domains)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BackupError.couldNotWrite(error.localizedDescription)
        }
    }

    func read(from url: URL) throws -> PawxyConfigurationBackup {
        do {
            return try decodedBackup(from: Data(contentsOf: url))
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.couldNotRead(error.localizedDescription)
        }
    }

    func encodedBackup(
        for domains: [LocalDomain],
        exportedAt: Date = Date()
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            return try encoder.encode(
                PawxyConfigurationBackup(domains: domains, exportedAt: exportedAt)
            )
        } catch {
            throw BackupError.couldNotWrite(error.localizedDescription)
        }
    }

    func decodedBackup(from data: Data) throws -> PawxyConfigurationBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let backup: PawxyConfigurationBackup
        do {
            backup = try decoder.decode(PawxyConfigurationBackup.self, from: data)
        } catch {
            throw BackupError.invalidFile(error.localizedDescription)
        }

        guard backup.formatVersion == PawxyConfigurationBackup.currentFormatVersion else {
            throw BackupError.unsupportedVersion(backup.formatVersion)
        }

        var names = Set<String>()
        for mapping in backup.mappings {
            var draft = LocalDomainDraft()
            draft.domain = mapping.domain
            draft.address = mapping.address
            draft.wildcard = mapping.wildcard
            draft.enabled = mapping.enabled

            guard draft.localDomain != nil else {
                throw BackupError.invalidMapping(mapping.domain)
            }
            guard names.insert(mapping.domain.lowercased()).inserted else {
                throw BackupError.duplicateMapping(mapping.domain)
            }
        }

        return backup
    }
}

extension PawxyBackupService {
    enum BackupError: LocalizedError, Equatable {
        case couldNotRead(String)
        case couldNotWrite(String)
        case invalidFile(String)
        case unsupportedVersion(Int)
        case invalidMapping(String)
        case duplicateMapping(String)

        var errorDescription: String? {
            switch self {
            case let .couldNotRead(detail):
                return String(localized: "Could not read the Pawxy backup: \(detail)")
            case let .couldNotWrite(detail):
                return String(localized: "Could not save the Pawxy backup: \(detail)")
            case let .invalidFile(detail):
                return String(localized: "This is not a valid Pawxy backup: \(detail)")
            case let .unsupportedVersion(version):
                return String(localized: "This backup uses unsupported format version \(version).")
            case let .invalidMapping(domain):
                return String(localized: "The backup contains an invalid mapping for \(domain).")
            case let .duplicateMapping(domain):
                return String(localized: "The backup contains more than one mapping for \(domain).")
            }
        }
    }
}
