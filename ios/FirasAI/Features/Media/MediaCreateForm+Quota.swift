import SwiftUI

// MARK: - Quota panel

/// What today allows. Images have a real read-only endpoint; video and music have none, so the
/// window rule is stated and the server's own `freesInMin` fills in after a refusal.
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
                Text(imageLine)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                Text(kind == .music ? Strings.Media.quotaMusicWindow(lang) : Strings.Media.quotaVideoWindow(lang))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                if let minutes = env.media.freesInMinutes[kind.rawValue] {
                    Text(Strings.Media.quotaFreesIn.fmt(lang, ArabicText.count(minutes, lang)))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                }
                Text(Strings.Media.quotaResets(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
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
