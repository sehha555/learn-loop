import Foundation

// MARK: - 考試與範圍
extension CardStore {
	func loadExams() {
		guard let data = try? Data(contentsOf: examsURL),
		      let decoded = try? JSONDecoder().decode([Exam].self, from: data)
		else { return }
		exams = decoded.sorted { $0.date < $1.date }
	}

	private func saveExams() {
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

	/// 最近一場還沒過的考試，清單頁頂端的倒數用
	var nextExam: Exam? {
		exams.first { $0.daysLeft >= 0 }
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

	/// 把附檔全部送給模型，整理出題型清單存在考試底下。只走 Mac 中繼站（要讀 PDF）
	func compileScope(for examID: UUID) async throws {
		guard let exam = exams.first(where: { $0.id == examID }), !exam.files.isEmpty else { return }
		let files = exam.files.compactMap { file -> AIClient.Attachment? in
			guard let data = try? Data(contentsOf: materialURL(exam: examID, file: file)) else { return nil }
			return AIClient.Attachment(name: "\(file.name).\(file.ext)", data: data)
		}
		let result = try await ai.compileScope(
			examName: exam.name, files: files, knownChapters: knownChapters)
		guard let index = exams.firstIndex(where: { $0.id == examID }) else { return }
		exams[index].scope = ExamScope(
			topics: result.topics, compiledAt: Date(), fallbackNote: result.fallbackNote)
		// 範圍整理出來的章自動勾上
		for topic in result.topics where !exams[index].chapters.contains(topic.chapter) && !topic.chapter.isEmpty {
			exams[index].chapters.append(topic.chapter)
		}
		saveExams()
	}
}
