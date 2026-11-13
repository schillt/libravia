import XCTest
@testable import BookCore

final class LocalLibraryTests: XCTestCase {
    func testDistinctFolderFilesWithIdenticalContentsStaySeparate() async throws {
        let namespace = "folder-test-\(UUID())"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))"))
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksSaved/\(stableKey(namespace))"))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixturePDF, to: folder.appendingPathComponent("First.pdf"))
        try FileManager.default.copyItem(at: fixturePDF, to: folder.appendingPathComponent("Second.pdf"))
        let folders = try LocalFolderLibrary(namespace: namespace)
        try await folders.select(folder)
        let entries = try await folders.refresh()
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotEqual(entries[0].id, entries[1].id)
        let library = try LocalLibrary(namespace: namespace)
        let first = try await folders.importBook(entries[0], into: library)
        let second = try await folders.importBook(entries[1], into: library)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.contentDigest, second.contentDigest)
    }
    func testSelectedFolderIndexesAndPreservesOriginalAndIdentity() async throws {
        let namespace = "folder-test-\(UUID())"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))"))
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksSaved/\(stableKey(namespace))"))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Shelf"), withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Shelf/First.pdf")
        try FileManager.default.copyItem(at: fixturePDF, to: original)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Outside.pdf"), withDestinationURL: fixturePDF)
        try Data("ignored".utf8).write(to: folder.appendingPathComponent("Shelf/readme.txt"))
        let folders = try LocalFolderLibrary(namespace: namespace)
        try await folders.select(folder)
        let initial = try await folders.refresh()
        XCTAssertEqual(initial.count, 1)
        let library = try LocalLibrary(namespace: namespace)
        let imported = try await folders.importBook(try XCTUnwrap(initial.first), into: library)
        XCTAssertEqual(imported.id, initial.first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let renamed = folder.appendingPathComponent("Shelf/Renamed.pdf")
        try FileManager.default.moveItem(at: original, to: renamed)
        let reopened = try LocalFolderLibrary(namespace: namespace)
        let refreshed = try await reopened.refresh()
        XCTAssertEqual(refreshed.filter(\.available).first?.id, imported.id)
        XCTAssertEqual(refreshed.filter(\.available).first?.relativePath, "Shelf/Renamed.pdf")
        let again = try await reopened.importBook(try XCTUnwrap(refreshed.first(where: \.available)), into: library)
        XCTAssertEqual(again.id, imported.id)
        let changed = try Data(contentsOf: fixturePDF) + Data("\n% changed".utf8)
        try changed.write(to: renamed)
        do { _ = try await reopened.importBook(try XCTUnwrap(refreshed.first(where: \.available)), into: library); XCTFail("Changed editions must not inherit old reading data") } catch {}
        XCTAssertEqual(try Data(contentsOf: renamed), changed)
        let saved = await library.directory(for: imported)
        XCTAssertNotNil(saved)
        try await library.remove(imported)
        do { _ = try await reopened.importBook(try XCTUnwrap(refreshed.first(where: \.available)), into: library); XCTFail("Changed editions must remain separate after device-copy removal") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        try FileManager.default.removeItem(at: renamed)
        let missing = try await reopened.refresh()
        XCTAssertEqual(missing.first?.id, imported.id)
        XCTAssertFalse(missing.first?.available ?? true)
        try FileManager.default.removeItem(at: folder)
        do { _ = try await reopened.refresh(); XCTFail("An inaccessible folder must not become an empty successful catalog") } catch {}
        let preservedCatalog = await reopened.books
        XCTAssertEqual(preservedCatalog.first?.id, imported.id)
    }
    func testImportIsDurableAndDuplicatePreservesIdentity() async throws {
        let namespace = "local-import-test-\(UUID())"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        defer {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))"))
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksSaved/\(stableKey(namespace))"))
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("My Book.pdf")
        try FileManager.default.copyItem(at: fixturePDF, to: source)
        let library = try LocalLibrary(namespace: namespace)
        let imported = try await library.importFile(source)
        let duplicate = try await library.importFile(source)
        XCTAssertEqual(imported.id, duplicate.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let restored = try LocalLibrary(namespace: namespace)
        let catalog = await restored.catalog()
        XCTAssertEqual(catalog.map(\.id), [imported.id])
        XCTAssertEqual(catalog.first?.title, "My Book")
        let directory = await restored.directory(for: imported)
        XCTAssertNotNil(directory)
        let cover = await restored.cover(for: imported.id)
        XCTAssertNotNil(cover)
        // A pre-metadata catalog remains readable and is enriched without changing identity.
        let index = support.appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))/catalog.json")
        let legacy = "[{\"id\":\"\(imported.id)\",\"title\":\"My Book\",\"format\":\"pdf\"}]"
        try Data(legacy.utf8).write(to: index)
        let migrated = try LocalLibrary(namespace: namespace)
        let enriched = await migrated.catalog()
        XCTAssertEqual(enriched.first?.id, imported.id)
        XCTAssertEqual(enriched.first?.hasCover, true)
    }

    func testRejectedImportIsNotListed() async throws {
        let namespace = "local-import-test-\(UUID())"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        defer {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))"))
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksSaved/\(stableKey(namespace))"))
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("not a pdf".utf8).write(to: source)
        let library = try LocalLibrary(namespace: namespace)
        do { _ = try await library.importFile(source); XCTFail("Invalid content must not be imported") } catch {}
        let catalog = await library.catalog()
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor func testRemovingAndReimportingKeepsReadingData() async throws {
        let namespace = "local-import-test-\(UUID())"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        defer {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))"))
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksSaved/\(stableKey(namespace))"))
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.copyItem(at: fixturePDF, to: source)
        let library = try LocalLibrary(namespace: namespace)
        let store = try ReadingStore(namespace: namespace)
        let otherNamespace = "other-account-\(UUID())"
        let otherStore = try ReadingStore(namespace: otherNamespace)
        defer { try? store.delete() }
        defer { try? otherStore.delete() }
        let entry = try await library.importFile(source)
        try store.add(Bookmark(name: "Saved", position: .init(page: 2)), id: entry.id)
        try store.set(ReadingRecord(position: .init(page: 2), acknowledgedTicks: 0, dirty: false,
                                    updated: Date(), title: entry.title, format: .pdf), id: entry.id)
        let annotation = ReadingAnnotation(anchor: .page(2), note: "Remember this", color: nil)
        try store.saveAnnotation(annotation, id: entry.id)
        try otherStore.add(Bookmark(name: "Different account", position: .init(page: 1)), id: entry.id)
        try await library.remove(entry)
        let removedCatalog = await library.catalog()
        XCTAssertTrue(removedCatalog.isEmpty)
        XCTAssertEqual(store.bookmarks[entry.id]?.count, 1)
        // Recreate both stores to exercise the relaunch path before re-importing.
        let reopenedLibrary = try LocalLibrary(namespace: namespace)
        let reopenedStore = try ReadingStore(namespace: namespace)
        XCTAssertEqual(reopenedStore.records[entry.id]?.position.page, 2)
        XCTAssertEqual(reopenedStore.bookmarks[entry.id]?.count, 1)
        XCTAssertEqual(reopenedStore.annotations[entry.id]?.first?.note, "Remember this")
        let reopenedOther = try ReadingStore(namespace: otherNamespace)
        XCTAssertNil(reopenedOther.records[entry.id])
        XCTAssertNil(reopenedOther.annotations[entry.id])
        XCTAssertEqual(reopenedOther.bookmarks[entry.id]?.first?.name, "Different account")
        let reimported = try await reopenedLibrary.importFile(source)
        XCTAssertEqual(entry.id, reimported.id)
        XCTAssertEqual(reopenedStore.bookmarks[reimported.id]?.count, 1)
        XCTAssertEqual(reopenedStore.annotations[reimported.id]?.first?.id, annotation.id)
    }
}

extension LocalLibraryTests {
    func testEPUBMetadataAndContainedCover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container><rootfiles><rootfile full-path='OPS/book.opf'/></rootfiles></container>".utf8)
            .write(to: root.appendingPathComponent("META-INF/container.xml"))
        let opf = """
        <package xmlns='http://www.idpf.org/2007/opf'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>
        <dc:title> A Title </dc:title><dc:creator> An Author </dc:creator></metadata>
        <manifest><item id='cover' href='cover.png' properties='cover-image' media-type='image/png'/></manifest></package>
        """
        try Data(opf.utf8).write(to: root.appendingPathComponent("OPS/book.opf"))
        // A small original image is enough to exercise ImageIO downsampling.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+Xl1sAAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("OPS/cover.png"))
        let metadata = LocalBookMetadata.read(format: .epub, directory: root)
        XCTAssertEqual(metadata.title, "A Title")
        XCTAssertEqual(metadata.author, "An Author")
        XCTAssertNotNil(metadata.cover)
        let outsideName = "outside-\(UUID().uuidString).png"
        let outside = root.deletingLastPathComponent().appendingPathComponent(outsideName)
        defer { try? FileManager.default.removeItem(at: outside) }
        try png.write(to: outside)
        let unsafe = opf.replacingOccurrences(of: "cover.png", with: "../../\(outsideName)")
        try Data(unsafe.utf8).write(to: root.appendingPathComponent("OPS/book.opf"))
        XCTAssertNil(LocalBookMetadata.read(format: .epub, directory: root).cover)
    }
}

private var fixturePDF: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Harbor.pdf")
}
