import SubtitleCore
import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var capture: CaptureService

    var body: some View {
        Form {
            Section("สถานะ") {
                // Fixed two-line height so changing status text never shifts the panel.
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                LabeledContent("OCR ต่อเฟรม") {
                    Text(model.ocrMilliseconds > 0 ? String(format: "%.0f ms", model.ocrMilliseconds) : "–").monospacedDigit()
                }
                .font(.callout)
                LabeledContent("ข้อความขึ้น → ไทยขึ้น") {
                    Text(model.textToThai.map { String(format: "%.2f วินาที", $0) } ?? "–").monospacedDigit()
                }
                .font(.callout)
            }

            Section("โหมด") {
                Picker("อ่านข้อความ", selection: $model.settings.mode) {
                    Text("เฉพาะซับ").tag(OCRMode.subtitle)
                    Text("ทั้งจอ").tag(OCRMode.fullScreen)
                }
                .pickerStyle(.segmented)
                Text(model.settings.mode == .subtitle
                     ? "อ่านเฉพาะกรอบซับ แปลเป็นบรรทัดเดียว"
                     : "อ่านทั้งจอ แปลเมนู ภารกิจ คำอธิบายไอเทม และบทพูด แล้ววางคำแปลไว้ตรงตำแหน่งเดิม")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(model.settings.mode == .subtitle ? "แสดงกรอบสีเหลือง" : "แสดงกรอบข้อความที่รอแปล",
                       isOn: $model.settings.showROI)
            }

            if model.settings.mode == .subtitle {
            Section("กรอบซับ (ส่วนที่ OCR อ่าน)") {
                slider("บน", $model.settings.roiTop)
                slider("ล่าง", $model.settings.roiBottom)
                slider("ซ้าย", $model.settings.roiLeft)
                slider("ขวา", $model.settings.roiRight)
                Button("คืนค่าเริ่มต้น") {
                    let d = Settings()
                    model.settings.roiTop = d.roiTop
                    model.settings.roiBottom = d.roiBottom
                    model.settings.roiLeft = d.roiLeft
                    model.settings.roiRight = d.roiRight
                }
            }
            }

            Section("ซับไทย") {
                Picker("วิธีแสดง", selection: $model.settings.eraseOriginal) {
                    Text("ลบอังกฤษแล้ววางไทย").tag(true)
                    Text("กล่องดำทับ").tag(false)
                }
                LabeledContent("อ่านต่อวินาที") {
                    Stepper(value: $model.settings.ocrPerSecond, in: 1...15, step: 1) {
                        Text("\(Int(model.settings.ocrPerSecond))")
                    }
                }
                if model.settings.mode == .subtitle, !model.settings.eraseOriginal {
                    Picker("ตำแหน่ง", selection: $model.settings.coverOriginal) {
                        Text("ทับซับอังกฤษ").tag(true)
                        Text("เหนือซับอังกฤษ").tag(false)
                    }
                }
                if model.settings.eraseOriginal {
                    LabeledContent("ขนาดเทียบต้นฉบับ") {
                        HStack {
                            Slider(value: $model.settings.thaiSizeScale, in: 0.6...1.6, step: 0.05)
                            Text("\(Int(model.settings.thaiSizeScale * 100))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                if model.settings.mode == .subtitle, !model.settings.eraseOriginal {
                    LabeledContent("ขนาดตัวอักษร") {
                        Slider(value: $model.settings.fontSize, in: 18...64, step: 1)
                    }
                }
                Toggle("แสดงภาษาอังกฤษใต้คำแปล", isOn: $model.settings.showOriginal)
            }

            Section("เสียงจาก capture card") {
                Toggle("เล่นเสียงออกลำโพง Mac", isOn: $model.settings.playAudio)
                LabeledContent("ระดับเสียง") {
                    Slider(value: $model.settings.volume, in: 0...1)
                }
                .disabled(!model.settings.playAudio)
            }

            Section("การแปล") {
                Toggle("แสดงคำแปลจาก Apple ทันที (ในเครื่อง)", isOn: $model.settings.quickApple)
                if model.settings.quickApple, let err = model.apple.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Toggle("แทนที่ด้วยตัวแปลหลักเมื่อแปลเสร็จ", isOn: $model.settings.refine)
                Text("Apple ขึ้นภายใน ~0.05 วินาที แต่แปลตรงตัว ตัวแปลหลักช้ากว่า (~1–2 วินาที) แต่เข้าใจบริบทเกม")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ตัวแปลหลัก") {
                Picker("ตัวแปล", selection: $model.settings.backend) {
                    Text("Claude (คลาวด์)").tag(TranslatorBackend.claude)
                    Text("Ollama (ในเครื่อง)").tag(TranslatorBackend.ollama)
                }
                .pickerStyle(.segmented)
                switch model.settings.backend {
                case .claude:
                    SecureField("Anthropic API key", text: $model.apiKey)
                    Button("บันทึก key ลง Keychain") { model.saveAPIKey() }
                    TextField("โมเดล", text: $model.settings.model)
                    Text("claude-opus-5-5 แปลได้ดีที่สุด, claude-haiku-5-5 เร็วและถูกกว่า")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ollama:
                    TextField("โมเดล Ollama", text: $model.settings.ollamaModel)
                    TextField("Ollama URL", text: $model.settings.ollamaURL)
                    Text("ไม่ใช้เน็ตและไม่มีค่าใช้จ่าย ต้องเปิด Ollama และโหลดโมเดลไว้ก่อน (ollama pull \(model.settings.ollamaModel))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("ข้อมูลเกม (ชื่อเกม ตัวละคร โทนภาษา)", text: $model.settings.gameContext, axis: .vertical)
                    .lineLimit(2...5)
                Button("ล้างบริบทการแปล (เปลี่ยนเกม/ฉาก)") { model.resetContext() }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ label: String, _ value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: 0...1)
                Text("\(Int(value.wrappedValue * 100))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
