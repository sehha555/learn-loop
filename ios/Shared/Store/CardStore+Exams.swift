import Foundation

// MARK: - 考試與範圍
extension CardStore {
	func loadExams() {
		guard let data = try? Data(contentsOf: examsURL),
		      let decoded = try? JSONDecoder().decode([Exam].self, from: data)
		else { return }
		exams = decoded.sorted { $0.date < $1.date }
	}

	func saveExams() {
		exams.sort { $0.date < $1.date }
		guard let data = try? JSONEncoder().encode(exams) else { return }
		try? data.write(to: examsURL, options: .atomic)
	}

	func addExam(_ exam: Exam) {
		exams.append(exam)
		saveExams()
	}

	func updateExam(_ exam: Exam) {
		guard let index = exams.firstIndex(where: { $0.id == exam.id }) else { return }
		exams[index] = exam
		saveExams()
	}

	func deleteExam(_ examID: UUID) {
		exams.removeAll { $0.id == examID }
		try? FileManager.default.removeItem(at: materialsDir.appendingPathComponent(examID.uuidString))
		saveExams()
	}

	// MARK: 附檔

	func materialURL(exam examID: UUID, file: ExamFile) -> URL {
		materialsDir.appendingPathComponent(examID.uuidString, isDirectory: true)
			.appendingPathComponent("\(file.id.uuidString).\(file.ext)")
	}

	/// 從檔案 app 選進來的檔複製一份進 materials/。來源是 security-scoped URL，要先開權限
	func addMaterial(to examID: UUID, from source: URL) throws {
		guard let index = exams.firstIndex(where: { $0.id == examID }) else { return }
		let accessing = source.startAccessingSecurityScopedResource()
		defer { if accessing { source.stopAccessingSecurityScopedResource() } }
		let file = ExamFile(name: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension.lowercased())
		let target = materialURL(exam: examID, file: file)
		try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: source, to: target)
		exams[index].files.append(file)
		saveExams()
	}

	func removeMaterial(from examID: UUID, file: ExamFile) {
		guard let index = exams.firstIndex(where: { $0.id == examID }) else { return }
		try? FileManager.default.removeItem(at: materialURL(exam: examID, file: file))
		exams[index].files.removeAll { $0.id == file.id }
		saveExams()
	}

	// MARK: 整理範圍

	/// 把附檔全部送給模型整理會考的題型 —— 題型內容寫進各概念頁的「會怎麼考」，
	/// 考試底下只記涵蓋哪些概念。只走 Mac 中繼站（要讀 PDF）
	func compileScope(for examID: UUID) async throws {
		guard let exam = exams.first(where: { $0.id == examID }), !exam.files.isEmpty else { return }
		let files = exam.files.compactMap { file -> AIClient.Attachment? in
			guard let data = try? Data(contentsOf: materialURL(exam: examID, file: file)) else { return nil }
			return AIClient.Attachment(name: "\(file.name).\(file.ext)", data: data)
		}
		let result = try await ai.compileScope(
			examName: exam.name, files: files, knownChapters: knownChapters,
			knownConcepts: knownConceptNames())
		guard let index = exams.firstIndex(where: { $0.id == examID }) else { return }
		// 重跑同一場：先把上次寫進各概念頁的第 4 塊清掉
		for key in wiki.keys {
			wiki[key]?.examTopics.removeAll { $0.examID == examID }
		}
		// 每型寫進它對到的概念頁；沒有頁就先立一頁只有第 4 塊的（講義骨架）
		var covered: [String] = []
		for topic in result.topics {
			let names = topic.concepts
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			for name in names {
				var page = wiki[name] ?? WikiPage(
					what: "", figure: nil, links: [], uses: "", examTopics: [],
					compiledAt: Date(), materialCount: 0, fallbackNote: nil)
				page.examTopics.append(ExamTopic(
					name: topic.name, examples: topic.examples, howTo: topic.howTo, examID: examID))
				wiki[name] = page
				// 新概念跟著題型的章走；已分章的不動（assignChapter 本來就只填空）
				assignChapter(topic.chapter, to: [name])
				if !covered.contains(name) { covered.append(name) }
			}
		}
		saveWiki()
		exams[index].scope = ExamScope(
			concepts: covered, compiledAt: Date(), fallbackNote: result.fallbackNote)
		// 範圍整理出來的章自動勾上
		for topic in result.topics where !exams[index].chapters.contains(topic.chapter) && !topic.chapter.isEmpty {
			exams[index].chapters.append(topic.chapter)
		}
		saveExams()
	}
}
