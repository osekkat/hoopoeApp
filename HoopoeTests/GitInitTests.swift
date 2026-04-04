import Foundation
import Testing
@testable import Hoopoe

@Suite("initGitRepoWithFileManager")
struct GitInitTests {

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitInitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func createsGitDirectory() throws {
        try withTempDir { dir in
            initGitRepoWithFileManager(at: dir)
            let gitDir = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }

    @Test func createsHEADFile() throws {
        try withTempDir { dir in
            initGitRepoWithFileManager(at: dir)
            let headURL = dir.appendingPathComponent(".git/HEAD")
            let content = try String(contentsOf: headURL, encoding: .utf8)
            #expect(content == "ref: refs/heads/main\n")
        }
    }

    @Test func createsConfigFile() throws {
        try withTempDir { dir in
            initGitRepoWithFileManager(at: dir)
            let configURL = dir.appendingPathComponent(".git/config")
            let content = try String(contentsOf: configURL, encoding: .utf8)
            #expect(content.contains("[core]"))
            #expect(content.contains("repositoryformatversion = 0"))
            #expect(content.contains("bare = false"))
        }
    }

    @Test func createsObjectsDirectories() throws {
        try withTempDir { dir in
            initGitRepoWithFileManager(at: dir)
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false

            let objectsInfo = git.appendingPathComponent("objects/info")
            #expect(FileManager.default.fileExists(atPath: objectsInfo.path, isDirectory: &isDir))
            #expect(isDir.boolValue)

            let objectsPack = git.appendingPathComponent("objects/pack")
            #expect(FileManager.default.fileExists(atPath: objectsPack.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }

    @Test func createsRefsDirectories() throws {
        try withTempDir { dir in
            initGitRepoWithFileManager(at: dir)
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false

            let refsHeads = git.appendingPathComponent("refs/heads")
            #expect(FileManager.default.fileExists(atPath: refsHeads.path, isDirectory: &isDir))
            #expect(isDir.boolValue)

            let refsTags = git.appendingPathComponent("refs/tags")
            #expect(FileManager.default.fileExists(atPath: refsTags.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }

    @Test func idempotentOnExistingRepo() throws {
        try withTempDir { dir in
            initGitRepoWithFileManager(at: dir)
            initGitRepoWithFileManager(at: dir)

            let headURL = dir.appendingPathComponent(".git/HEAD")
            let content = try String(contentsOf: headURL, encoding: .utf8)
            #expect(content == "ref: refs/heads/main\n")
        }
    }

    @Test func passesIsGitRepoCheck() throws {
        try withTempDir { dir in
            initGitRepoWithFileManager(at: dir)
            let gitPath = dir.appendingPathComponent(".git").path
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir)
            #expect(exists && isDir.boolValue)
        }
    }
}
