import SwiftUI

// MARK: - Quota panel

/// What today allows **for the kind on screen**. Images have a real read-only endpoint; video and
/// music have none, so the window rule is stated and the server's own `freesInMin` fills in after a
/// refusal.
///
/// Exactly one allowance line, never three. The panel is already scoped to `kind` — it reads
/// `freesInMinutes[kind.rawValue]` — so printing the image count on the song tab, or "6 clips every
/// 2 hours" on the image tab, was three lines of noise where one is true. The midnight reset
/// sentence belongs to the daily image limit alone; the video and music allowances are rolling
/// two-hour windows and do not reset at midnight.
@MainActor
struct MediaQuotaPanel: View {

    let env: AppEnvironment
    let kind: MediaKind

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        SurfaceCard(palette: palette) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Strings.Media.quotaTitle(lang))
                    .font(FirasType.label)
                    .foregroundStyle(palette.textMuted)
                Text(allowanceLine)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                if let minutes = env.media.freesInMinutes[kind.rawValue] {
                    Text(Strings.Media.quotaFreesIn.fmt(lang, ArabicText.count(minutes, lang)))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                }
                if kind == .image {
                    Text(Strings.Media.quotaResets(lang))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The one line that is true for this kind.
    private var allowanceLine: String {
        switch kind {
        case .image: return imageLine
        case .video: return Strings.Media.quotaVideoWindow(lang)
        case .music: return Strings.Media.quotaMusicWindow(lang)
        }
    }

    private var imageLine: String {
        if env.media.imageQuotaBlocked {
            return Strings.Media.imageWhyQuota(lang)
        }
        guard let quota = env.media.imageQuota, let limit = quota.limit else {
            return Strings.Media.quotaImagesUnknown(lang)
        }
        guard limit >= 0 else { return Strings.Media.quotaImagesUnmetered(lang) }
        let used = quota.used ?? 0
        return Strings.Media.quotaImages.fmt(
            lang,
            ArabicText.count(used, lang),
            ArabicText.count(limit, lang)
        )
    }
}
