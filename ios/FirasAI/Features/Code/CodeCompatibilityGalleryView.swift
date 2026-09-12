#if DEBUG
import SwiftUI
import Perception

/// Uses the actual workspace and picker. Its caller supplies an isolated, unauthenticated env.
@MainActor
struct CodeCompatibilityGalleryView: View {
    enum Surface { case workspace, models }

    let env: AppEnvironment
    let surface: Surface
    static let projectID = "native-gallery-code-project"

    static func prepare(env: AppEnvironment) {
        let project = CodeProject(name: "مشروع بايثون", files: [
            CodeFile(path: "main.py", content: "def total(values):\n    return sum(values)\n\nprint(total([3, 5, 8]))\n"),
            CodeFile(path: "README.md", content: "# مشروع بايثون\n\nمثال محلي لاختبار واجهة المحرر.\n")
        ])
        var question = CodeChatMessage(role: "user", content: "اشرح لي المشروع ووضح طريقة تشغيله.", at: 1_789_200_000_000)
        question.id = "native-gallery-code-question"
        var answer = CodeChatMessage(role: "ai", content: """
        المشروع يحتوي ملفين:

        **main.py** يحسب مجموع القيم، و**README.md** يشرح طريقة التشغيل.

        افتح الطرفية داخل مجلد المشروع وشغّل:

        ```bash
        python main.py
        ```

        النتيجة المتوقعة هي **16**. يمكنك تعديل القيم في الملف ثم تشغيله من جديد.
        """, at: 1_789_200_001_000)
        answer.id = "native-gallery-code-answer"
        answer.model = ModelTier.pro.rawValue
        env.code.installCompatibilityGallery(projectID: projectID, project: project,
            thread: CodeChatThread(messages: [question, answer], selection: CodeModelSelection(model: .pro)))
    }

    var body: some View {
        WithPerceptionTracking {
            switch surface {
            case .workspace:
                FirasNavigationStack {
                    CodeWorkspaceView(env: env, projectID: Self.projectID)
                }
            case .models:
                CodeModelPicker(env: env)
            }
        }
    }
}
#endif
