import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 考試 tab：哪天考、範圍哪幾章、講義／作業附檔、模型整理出的題型。
/// 這是 app 第一次有「範圍」—— 之後出題、判「還沒練到」都靠這裡
struct ExamListView: View {
	@ObservedObject var store: CardStore
	@State private var adding = false

	var body: some View {
		NavigationStack {
			List {
				if store.exams.isEmpty {
					Text("還沒有考試。按右上角加一場，把講義和作業的 PDF 附上去，模型會整理出會考的題型。")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				ForEach(store.exams) { exam in
					NavigationLink(value: exam.id) {
						HStack(alignment: .firstTextBaseline) {
							VStack(alignment: .leading, spacing: 4) {
								Text(exam.name).font(.headline)
								Text(exam.date.formatted(date: .abbreviated, time: .omitted))
									.font(.caption)
									.foregroundStyle(.secondary)
								if !exam.chapters.isEmpty {
									Text(exam.chapters.joined(separator: "、"))
										.font(.caption)
										.foregroundStyle(.secondary)
										.lineLimit(1)
								}
							}
							Spacer()
							countdown(exam)
						}
						.padding(.vertical, 4)
					}
				}
				.onDelete { offsets in
					for offset in offsets { store.deleteExam(store.exams[offset].id) }
				}
			}
			.navigationTitle("考試")
			.toolbar {
				ToolbarItem(placement: .primaryAction) {
					Button("加一場", systemImage: "plus") { adding = true }
				}
			}
			.navigationDestination(for: UUID.self) { examID in
				ExamDetailView(store: store, examID: examID)
			}
			.sheet(isPresented: $adding) {
				NewExamSheet(store: store)
			}
		}
	}

	private func countdown(_ exam: Exam) -> some View {
		let days = exam.daysLeft
		let text = days < 0 ? "考完了" : days == 0 ? "今天" : "\(days) 天後"
		return Text(text)
			.font(.subheadline.weight(.semibold))
			.foregroundStyle(days <= 3 && days >= 0 ? .red : .secondary)
	}
}

/// 新增：只要名字和日期，其他進去再補
private struct NewExamSheet: View {
	@ObservedObject var store: CardStore
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()

	var body: some View {
		NavigationStack {
			Form {
				TextField("考試名稱（微積分期中）", text: $name)
				DatePicker("日期", selection: $date, displayedComponents: .date)
			}
			.navigationTitle("加一場考試")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("加入") {
						store.addExam(Exam(name: name.trimmingCharacters(in: .whitespaces), date: date))
						dismiss()
					}
					.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
				}
			}
		}
		.presentationDetents([.medium])
	}
}

/// 一場考試的細節：日期、章、附檔、整理出的題型
struct ExamDetailView: View {
	@ObservedObject var store: CardStore
	let examID: UUID
	@State private var importing = false
	@State private var compiling: Task<Void, Never>?
	@State private var errorText: String?
	@State private var previewing: URL?

	private var exam: Exam? { store.exams.first { $0.id == examID } }

	var body: some View {
		if let exam {
			Form {
				Section {
					TextField("名稱", text: field(exam, \.name))
					DatePicker("日期", selection: field(exam, \.date), displayedComponents: .date)
					LabeledContent("倒數", value: exam.daysLeft < 0 ? "考完了" : "\(exam.daysLeft) 天")
				}

				Section("範圍（章）") {
					if store.knownChapters.isEmpty {
						Text("還沒有章——貼幾題或整理範圍後會出現").font(.caption).foregroundStyle(.secondary)
					}
					ForEach(store.knownChapters, id: \.self) { chapter in
						Toggle(chapter, isOn: Binding(
							get: { exam.chapters.contains(chapter) },
							set: { on in
								var edited = exam
								if on { edited.chapters.append(chapter) } else { edited.chapters.removeAll { $0 == chapter } }
								store.updateExam(edited)
							}))
					}
				}

				Section {
					ForEach(exam.files) { file in
						Button {
							previewing = store.materialURL(exam: examID, file: file)
						} label: {
							Label("\(file.name).\(file.ext)", systemImage: file.isPDF ? "doc.richtext" : "photo")
								.lineLimit(1)
						}
					}
					.onDelete { offsets in
						for offset in offsets { store.removeMaterial(from: examID, file: exam.files[offset]) }
					}
					Button("加檔案（PDF 或圖）", systemImage: "plus") { importing = true }
				} header: {
					Text("講義與作業")
				} footer: {
					Text("GoodNotes 匯出成 PDF（含手寫）存到 iCloud 雲碟，這裡選進來。")
				}

				Section {
					if compiling != nil {
						HStack {
							ProgressView().controlSize(.small)
							Text("模型在讀檔案（幾十頁要三到八分鐘）…").font(.caption).foregroundStyle(.secondary)
							Spacer()
							Button("取消") { compiling?.cancel() }.font(.caption)
						}
					} else {
						Button(exam.scope == nil ? "整理範圍" : "重新整理範圍", systemImage: "wand.and.stars") { compile() }
							.disabled(exam.files.isEmpty)
					}
					if let scope = exam.scope {
						ForEach(Array(scope.topics.enumerated()), id: \.offset) { index, topic in
							VStack(alignment: .leading, spacing: 6) {
								HStack(alignment: .firstTextBaseline) {
									Text("\(index + 1). \(topic.name)").font(.headline)
									Spacer()
									Text(topic.chapter).font(.caption).foregroundStyle(.secondary)
								}
								MathText(text: topic.howTo, font: .callout, size: 16)
									.foregroundStyle(.primary.opacity(0.85))
								ForEach(Array(topic.examples.components(separatedBy: "\n").filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, line in
									HStack(alignment: .firstTextBaseline, spacing: 6) {
										Text("•").foregroundStyle(.secondary)
										MathText(text: line, font: .callout, size: 16)
									}
								}
							}
							.padding(.vertical, 4)
						}
						if let note = scope.fallbackNote {
							Label(note, systemImage: "icloud.and.arrow.down").font(.caption2).foregroundStyle(.orange)
						}
						Text("整理於 \(scope.compiledAt.formatted(date: .abbreviated, time: .shortened))")
							.font(.caption2).foregroundStyle(.tertiary)
					}
				} header: {
					Text("會考的題型")
				}
			}
			.navigationTitle(exam.name)
			.navigationBarTitleDisplayMode(.inline)
			.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
				switch result {
				case let .success(urls):
					for url in urls {
						do { try store.addMaterial(to: examID, from: url) } catch { errorText = error.localizedDescription }
					}
				case let .failure(error):
					errorText = error.localizedDescription
				}
			}
			.quickLookPreview($previewing)
			.errorAlert($errorText)
		} else {
			Text("這場考試已經刪掉了").foregroundStyle(.secondary)
		}
	}

	/// 表單欄位直接綁到 store：改一個欄位就整筆存檔
	private func field<T>(_ exam: Exam, _ keyPath: WritableKeyPath<Exam, T>) -> Binding<T> {
		Binding(
			get: { exam[keyPath: keyPath] },
			set: { var edited = exam; edited[keyPath: keyPath] = $0; store.updateExam(edited) })
	}

	private func compile() {
		compiling = Task { @MainActor in
			defer { compiling = nil }
			do { try await store.compileScope(for: examID) } catch {
				guard !AIClient.isCancellation(error) else { return }
				errorText = error.localizedDescription
			}
		}
	}
}
