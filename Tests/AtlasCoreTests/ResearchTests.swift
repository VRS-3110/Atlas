import Foundation
import Testing
@testable import AtlasCore

@Suite("BibTeX")
struct BibTeXTests {
    static let sample = #"""
    @comment{ written by hand }
    @string{ jmb = "Journal of Molecular Biology" }
    @Article{watson1953,
      author = {Watson, James D. and Francis Crick},
      title = {Molecular Structure of {Nucleic Acids}: A Structure for Deoxyribose Nucleic Acid},
      journal = jmb # " (letters)",
      year = 1953, month = apr,
      volume = "171", pages = {737--738},
      doi = {10.1038/171737a0},
      keywords = {DNA, structure},
      note = {Famous {\"u}ber-paper}
    }
    @book{darwin,
      author = "Charles Darwin",
      title = "On the Origin of Species",
      publisher = {John Murray}, year = {1859}
    }
    """#

    @Test func parsesEntriesFieldsAndMacros() {
        let entries = BibTeX.parse(Self.sample)
        #expect(entries.count == 2)
        let watson = entries[0]
        #expect(watson.type == "article")
        #expect(watson.key == "watson1953")
        #expect(watson["journal"] == "Journal of Molecular Biology (letters)")
        #expect(watson["month"] == "April")
        #expect(watson["year"] == "1953")
        #expect(watson["title"] == "Molecular Structure of {Nucleic Acids}: A Structure for Deoxyribose Nucleic Acid")
        #expect(entries[1]["publisher"] == "John Murray")
    }

    @Test func decodesLaTeX() {
        #expect(BibTeX.decodeLaTeX(#"Schr{\"o}dinger and \"Uber \'Etude"#) == "Schrödinger and Über Étude")
        #expect(BibTeX.decodeLaTeX(#"G\"{o}del, Ma{\ss}e \& 10\% pages 1--2, \c{c}a"#) == "Gödel, Maße & 10% pages 1–2, ça")
        #expect(BibTeX.decodeLaTeX(#"{DNA} \emph{in vivo} \cite{x}"#) == "DNA in vivo x")
        #expect(BibTeX.encodeLaTeX("R&D 50% #1_a") == ##"R\&D 50\% \#1\_a"##)
    }

    @Test func normalisesAuthorNames() {
        #expect(BibTeX.authors(from: "Watson, James D. and Francis Crick") == ["Watson, James D.", "Crick, Francis"])
        #expect(BibTeX.authors(from: "Ludwig van Beethoven and {World Health Organization}")
                == ["van Beethoven, Ludwig", "World Health Organization"])
        #expect(BibTeX.authors(from: "{Barnes and Noble}") == ["Barnes and Noble"])
    }

    @Test func convertsEntriesToSources() {
        let imported = BibTeX.source(from: BibTeX.parse(Self.sample)[0])
        #expect(imported.title == "Molecular Structure of Nucleic Acids: A Structure for Deoxyribose Nucleic Acid")
        #expect(imported.info.authors == ["Watson, James D.", "Crick, Francis"])
        #expect(imported.info.year == 1953)
        #expect(imported.info.pages == "737–738")
        #expect(imported.info.doi == "10.1038/171737a0")
        #expect(imported.info.citationKey == "watson1953")
        #expect(imported.tags == ["DNA", "structure"])
        #expect(imported.info.extraFields["note"] == #"Famous {\"u}ber-paper"#)
        #expect(imported.info.extraFields["month"] == "April")
    }

    @Test func exportRoundTrips() {
        for entry in BibTeX.parse(Self.sample) {
            let source = BibTeX.source(from: entry)
            let written = BibTeX.format(BibTeX.entry(title: source.title, info: source.info, tags: source.tags))
            let reread = BibTeX.parse(written)
            #expect(reread.count == 1)
            #expect(BibTeX.source(from: reread[0]) == source)
        }
        let text = BibTeX.format(BibTeX.entry(title: "R&D: 50% done", info: SourceInfo(entryType: "inproceedings",
                                                                                     container: "Proc. ACM", citationKey: "k")))
        #expect(text.contains(#"title = {R\&D: 50\% done}"#))
        #expect(text.contains("booktitle = {Proc. ACM}"))
    }

    @Test func skipsMalformedInput() {
        #expect(BibTeX.parse("no entries here").isEmpty)
        let entries = BibTeX.parse("@article{broken, title = {Unclosed\n@book{ok, title={Fine}}")
        #expect(entries.contains { $0.key == "ok" && $0["title"] == "Fine" })
    }
}

@Suite("Citations")
struct CitationTests {
    @Test func keysFollowAuthorYearWord() {
        let info = SourceInfo(authors: ["Müller-Lüdenscheidt, Hans"], year: 2021)
        #expect(CitationKey.base(title: "The Theory of Everything", info: info) == "mullerludenscheidt2021theory")
        #expect(CitationKey.base(title: "", info: SourceInfo()) == "source")
        let taken: Set = ["darwin1859origin", "Darwin1859origina"]
        let darwin = SourceInfo(authors: ["Darwin, Charles"], year: 1859)
        #expect(CitationKey.unique(title: "On the Origin of Species", info: darwin, taken: taken) == "darwin1859originb")
        #expect(CitationKey.familyName("Charles Darwin") == "Darwin")
    }

    @Test func formatsInTextAndReferences() {
        let one = SourceInfo(authors: ["Darwin, Charles Robert"], year: 1859, publisher: "John Murray")
        #expect(CitationFormatter.inText(one, title: "Origin", page: "42") == "Darwin, 1859, p. 42")
        #expect(CitationFormatter.reference(one, title: "On the Origin of Species")
                == "Darwin, C. R. (1859). On the Origin of Species. John Murray.")
        let two = SourceInfo(authors: ["Watson, James", "Crick, Francis"], year: 1953, container: "Nature",
                             volume: "171", issue: "4356", pages: "737–738", doi: "10.1038/171737a0")
        #expect(CitationFormatter.inText(two, title: "", page: "737–738") == "Watson & Crick, 1953, pp. 737–738")
        #expect(CitationFormatter.reference(two, title: "Molecular Structure")
                == "Watson, J., & Crick, F. (1953). Molecular Structure. Nature, 171(4356), 737–738. https://doi.org/10.1038/171737a0")
        let many = SourceInfo(authors: ["A, B", "C, D", "E, F"])
        #expect(CitationFormatter.inText(many, title: "") == "A et al., n.d.")
    }
}

@Suite("Metadata")
struct MetadataTests {
    @Test func findsDOIs() {
        #expect(DOI.normalize("https://doi.org/10.1038/171737a0") == "10.1038/171737a0")
        #expect(DOI.normalize("doi:10.1000/xyz123.") == "10.1000/xyz123")
        #expect(DOI.normalize("see (10.1002/(SICI)1097-4571(199806)49:8<693::AID-ASI4>3.0.CO;2-0)") != nil)
        #expect(DOI.normalize("https://doi.org/10.1016%2Fj.cell.2009.01.002") == "10.1016/j.cell.2009.01.002")
        #expect(DOI.normalize("no identifier") == nil)
    }

    static let crossref = #"""
    {"status":"ok","message":{"DOI":"10.1038/171737a0","type":"journal-article",
     "title":["Molecular Structure of Nucleic Acids"],"subtitle":["A Structure for Deoxyribose Nucleic Acid"],
     "author":[{"given":"J. D.","family":"Watson"},{"given":"F. H. C.","family":"Crick"},{"name":"Nature Staff"}],
     "container-title":["Nature"],"publisher":"Springer","volume":"171","issue":"4356","page":"737-738",
     "issued":{"date-parts":[[1953,4]]},"URL":"https://doi.org/10.1038/171737a0",
     "abstract":"<jats:p>We wish to suggest a structure &amp; more.</jats:p>"}}
    """#

    @Test func parsesCrossrefWorks() throws {
        let work = try CrossrefParser.parse(Data(Self.crossref.utf8))
        #expect(work.title == "Molecular Structure of Nucleic Acids: A Structure for Deoxyribose Nucleic Acid")
        #expect(work.info.authors == ["Watson, J. D.", "Crick, F. H. C.", "Nature Staff"])
        #expect(work.info.year == 1953)
        #expect(work.info.entryType == "article")
        #expect(work.info.pages == "737–738")
        #expect(work.info.container == "Nature")
        #expect(work.abstract == "We wish to suggest a structure & more.")
        #expect(throws: CrossrefParser.ParseError.self) { try CrossrefParser.parse(Data("{}".utf8)) }
    }

    static let page = #"""
    <html><head><title>Ignored &amp; fallback</title>
    <meta name="citation_title" content="Deep Learning for Cells">
    <meta name="citation_author" content="Ada Lovelace"><meta name="citation_author" content="Turing, Alan">
    <meta name="citation_publication_date" content="2019/05/02">
    <meta name="citation_journal_title" content="Cell Systems">
    <meta name='citation_doi' content='doi:10.1016/j.cels.2019.04.001'>
    <meta name="citation_firstpage" content="10"><meta name="citation_lastpage" content="20">
    <meta property="og:site_name" content="CellPress">
    </head><body></body></html>
    """#

    @Test func parsesPageMetadata() {
        let meta = PageMetadataParser.parse(html: Self.page, url: URL(string: "https://example.org/a"))
        #expect(meta.title == "Deep Learning for Cells")
        #expect(meta.info.authors == ["Lovelace, Ada", "Turing, Alan"])
        #expect(meta.info.year == 2019)
        #expect(meta.info.container == "Cell Systems")
        #expect(meta.info.doi == "10.1016/j.cels.2019.04.001")
        #expect(meta.info.pages == "10–20")
        #expect(meta.info.entryType == "article")
        let plain = PageMetadataParser.parse(html: "<title> A &#8216;plain&#x2019; page </title>", url: nil)
        #expect(plain.title == "A ‘plain’ page")
    }

    @Test func fetcherUsesCrossrefForDOIsAndPages() async throws {
        let crossref = Data(Self.crossref.utf8)
        let page = Data(Self.page.utf8)
        let fetcher = MetadataFetcher { request in
            let url = request.url!.absoluteString
            let body = url.contains("api.crossref.org") ? crossref : page
            let status = url.contains("missing") ? 404 : 200
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let byDOI = try await fetcher.lookUp("https://doi.org/10.1038/171737a0")
        #expect(byDOI.info.container == "Nature")
        // The page names a DOI, so Crossref completes it; the page's address is kept.
        let byPage = try await fetcher.lookUp("https://example.org/article")
        #expect(byPage.info.doi == "10.1038/171737a0")
        await #expect(throws: MetadataFetcher.FetchError.self) { try await fetcher.lookUp("https://example.org/missing") }
        await #expect(throws: MetadataFetcher.FetchError.self) { try await fetcher.lookUp("just words") }
    }
}

@Suite("Capture")
struct CaptureTests {
    @Test func appliesCaptureRules() {
        let note = CaptureParser.node(from: "Check sampling bias #methods #Stats\nmore detail")
        #expect(note.title == "Check sampling bias")
        #expect(note.tags == ["methods", "Stats"])
        #expect(note.body == "more detail")
        #expect(note.kind == .note && note.inbox == .inbox)
        #expect(CaptureParser.node(from: "Why does it fail?").kind == .question)
        let task = CaptureParser.node(from: "[] email the lab")
        #expect(task.kind == .task && task.title == "email the lab" && task.task != nil)
        #expect(CaptureParser.node(from: "> To be or not").kind == .quote)
        #expect(CaptureParser.node(from: "“Quoted words”").title == "Quoted words")
        let link = CaptureParser.node(from: "https://www.example.com/papers/cells")
        #expect(link.kind == .source && link.source?.url == "https://www.example.com/papers/cells")
        #expect(link.title == "example.com/papers/cells")
        let doi = CaptureParser.node(from: "10.1038/171737a0")
        #expect(doi.kind == .source && doi.source?.doi == "10.1038/171737a0")
        #expect(CaptureParser.node(from: "Anything", kind: .idea).kind == .idea)
        let long = CaptureParser.node(from: String(repeating: "word ", count: 60))
        #expect(long.title.count <= 81 && long.body.count > 200)
    }
}

@MainActor
@Suite("Research workspace")
struct ResearchWorkspaceTests {
    @Test func captureTriageAndArchive() {
        let f = Fixture()
        let w = f.workspace
        let item = w.capture("Read about #CRISPR")!
        #expect(w.inboxNodes.map(\.id) == [item.id])
        #expect(w.history.undoActionName == "Capture")
        let link = w.capture("https://example.org/paper")!
        #expect(!link.source!.citationKey.isEmpty)
        w.archive([item.id])
        #expect(w.inboxNodes.map(\.id) == [link.id])
        #expect(w.archivedNodes.map(\.id) == [item.id])
        #expect(w.searchNodes("CRISPR").isEmpty) // archived items stay out of search
        w.unarchive([item.id])
        w.convertToTasks([item.id])
        #expect(item.inbox == .none && item.task != nil && item.kind == .note)
        w.placeNode(link.id, on: f.map.id, at: .zero)
        #expect(link.inbox == .none && w.placement(of: link.id, in: f.map.id) != nil)
    }

    @Test func convertingToSourceAssignsAUniqueKey() {
        let f = Fixture()
        let w = f.workspace
        let a = w.addSource(title: "Origin of Species", info: SourceInfo(authors: ["Darwin, Charles"], year: 1859))
        #expect(a.source?.citationKey == "darwin1859origin")
        let b = w.capture("Origin of species")!
        w.updateNode(b, "Edit") { $0.link = "https://x.org" }
        w.convertToSources([b.id])
        #expect(b.kind == .source && b.inbox == .none && b.source?.url == "https://x.org")
        #expect(b.source?.citationKey == "origin")
        w.updateNode(b, "Edit") { $0.source?.authors = ["Darwin, C."]; $0.source?.year = 1859 }
        w.regenerateCitationKey(b.id)
        #expect(b.source?.citationKey == "darwin1859origina")
    }

    @Test func importMergesDuplicatesInOneStep() {
        let f = Fixture()
        let w = f.workspace
        let existing = w.addSource(title: "Molecular Structure", info: SourceInfo(doi: "10.1038/171737A0", citationKey: "mine"))
        w.history.removeAll()
        let result = w.importBibTeX(BibTeXTests.sample)
        #expect(result.added.count == 1 && result.merged == [existing.id])
        #expect(existing.source?.year == 1953 && existing.source?.citationKey == "mine")
        #expect(existing.title == "Molecular Structure") // titles the user set are kept
        #expect(w.sourceNodes.count == 2)
        #expect(w.history.undoStack.count == 1 && w.history.undoActionName == "Import Sources")
        w.undo()
        #expect(w.sourceNodes.count == 1 && existing.source?.year == nil)
        // Exporting and importing again adds nothing new.
        w.redo()
        let again = w.importBibTeX(w.bibTeX())
        #expect(again.added.isEmpty && again.merged.count == 2)
    }

    @Test func quotesAndCitations() {
        let f = Fixture()
        let w = f.workspace
        let source = w.addSource(title: "Origin", info: SourceInfo(authors: ["Darwin, Charles"], year: 1859))
        let quote = w.addQuote("Endless forms most beautiful", page: "490", sourceID: source.id, on: f.map.id,
                               at: .zero, parent: f.root)!
        #expect(w.quotes(of: source.id).map(\.id) == [quote.id])
        #expect(w.citationText(for: quote.id) == "“Endless forms most beautiful” (Darwin, 1859, p. 490)\n\nDarwin, C. (1859). Origin.")
        #expect(w.citationText(for: source.id) == "Darwin, C. (1859). Origin.")
        // Removing a quote from its map keeps it in the source's quote list.
        w.removeFromMap([quote.id], mapID: f.map.id)
        #expect(w.nodes[quote.id] != nil)
        w.addCitation(from: f.a, to: source.id, page: "12")
        #expect(w.usage(of: source.id).citing.count == 2)
        #expect(w.usage(of: source.id).maps.map(\.id) == [f.map.id])
        #expect(w.citationText(for: f.a)?.hasPrefix("A (Darwin, 1859, p. 12)") == true)
        w.setCitationPage("13", from: f.a, to: source.id)
        #expect(f.node(f.a)?.citations.first?.page == "13")
        w.removeCitation(from: f.a, to: source.id)
        #expect(f.node(f.a)?.citations.isEmpty == true)
        // Deleting the source removes citations to it.
        w.deleteNodes([source.id])
        #expect(w.nodes[quote.id]?.citations.isEmpty == true)
    }

    @Test func metadataFillsOnlyEmptyFields() {
        let f = Fixture()
        let w = f.workspace
        let node = w.capture("https://doi.org/10.1038/171737a0")!
        let fetched = try! CrossrefParser.parse(Data(MetadataTests.crossref.utf8))
        w.applyMetadata(fetched, to: node.id)
        #expect(node.title.hasPrefix("Molecular Structure"))
        #expect(node.source?.citationKey == "watson1953molecular")
        #expect(node.body.contains("We wish"))
        w.updateNode(node, "Edit") { $0.title = "My title"; $0.source?.volume = "999" }
        w.applyMetadata(fetched, to: node.id)
        #expect(node.title == "My title" && node.source?.volume == "999")
    }

    @Test func templatesInsertAsOneStep() {
        let f = Fixture()
        let w = f.workspace
        let before = w.placements(in: f.map.id).count
        let root = w.insertTemplate(.researchQuestion, in: f.map.id, under: f.b)!
        #expect(w.placements(in: f.map.id).count == before + ResearchTemplate.researchQuestion.structure.count)
        #expect(f.tree.parent[root] == f.b)
        #expect(f.tree.children(of: root).compactMap(f.title) == ["Hypothesis 1", "Hypothesis 2", "Open Questions"])
        #expect(w.history.undoStack.count == 1)
        w.undo()
        #expect(w.placements(in: f.map.id).count == before)

        let source = w.addSource(title: "S")
        let map = w.createMap(from: .literatureReview, sources: [source.id])
        let tree = w.tree(of: map.id)
        #expect(tree.roots.count == 1 && w.nodes[tree.roots[0]]?.title == "Literature Review")
        let unsorted = tree.children(of: tree.roots[0]).first { w.nodes[$0]?.title == "Unsorted Sources" }!
        #expect(tree.children(of: unsorted) == [source.id])
        #expect(w.history.undoActionName == "New Literature Review Map")
    }

    @Test func attachmentsAreCopiedIntoTheWorkspace() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let (w, _) = try Workspace.open(at: folder.storeURL)
        let file = folder.url.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        let source = w.addSource(title: "Paper")
        let attachment = try #require(try w.attachFile(at: file, to: source.id))
        #expect(attachment.originalName == "paper.pdf" && attachment.byteCount == 8)
        #expect(source.source?.attachmentID == attachment.id)
        let stored = try #require(w.document(of: source.id))
        #expect(FileManager.default.fileExists(atPath: stored.path))
        w.detach(attachment.id, from: source.id)
        #expect(source.attachments.isEmpty && source.source?.attachmentID == nil)
    }
}
