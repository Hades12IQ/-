import SwiftUI

struct ShellSidebar: View {
    @Binding var selectedProduct: ProductKind
    @Binding var compactSidebarPresented: Bool
    @Binding var presentedSheet: ShellSheet?
    let isCompact: Bool
    var onCloseSidebar: (() -> Void)? = nil

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery = ""

    private let products: [ProductKind] = [.ai, .agent, .code, .brain]

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            searchField
            sidebarList
            accountFooter
        }
        .background(preferences.palette.sidebar)
        .overlay(alignment: .trailing) {
            if isCompact {
                Rectangle()
                    .fill(preferences.palette.border.opacity(0.9))
                    .frame(width: 0.5)
                    .accessibilityHidden(true)
            }
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            FirasBrandMark(size: 30, showsWordmark: true)

            Spacer(minLength: 8)

            Button(action: createConversation) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(preferences.palette.textPrimary)
            .accessibilityLabel(Text(ShellStrings.newChat))

            if isCompact || onCloseSidebar != nil {
                Button(action: closeSidebar) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(preferences.palette.textSecondary)
                .accessibilityLabel(Text(ShellStrings.closeSidebar))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, isCompact ? 8 : 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(preferences.palette.textMuted)
                .accessibilityHidden(true)

            TextField(
                text: $searchQuery,
                prompt: Text(ShellStrings.searchChats)
            ) {
                Text(ShellStrings.searchChats)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(preferences.palette.textPrimary)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(preferences.palette.textMuted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ShellStrings.clearSearch))
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 7)
        .frame(minHeight: 44)
        .background(
            preferences.palette.surface,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(preferences.palette.border, lineWidth: 1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }

    private var sidebarList: some View {
        List {
            Section {
                ForEach(products) { product in
                    Button {
                        selectProduct(product)
                    } label: {
                        ProductSidebarRow(
                            product: product,
                            isSelected: selectedProduct == product
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(ShellStrings.products)
                    .foregroundStyle(preferences.palette.textMuted)
            }

            Section {
                if filteredConversations.isEmpty {
                    Text(ShellStrings.noChats)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredConversations) { conversation in
                        Button {
                            selectConversation(conversation.id)
                        } label: {
                            ConversationSidebarRow(
                                conversation: conversation,
                                isSelected: chatStore.selectedConversationID == conversation.id
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task {
                                    await chatStore.delete(conversation.id)
                                }
                            } label: {
                                Label {
                                    Text(ShellStrings.deleteChat)
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(ShellStrings.recent)
                    .foregroundStyle(preferences.palette.textMuted)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 48)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }

    private var accountFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(preferences.palette.border)

            HStack(spacing: 8) {
                Button {
                    presentedSheet = .authentication
                    dismissCompactSidebar()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: session.isAuthenticated ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(preferences.palette.accent)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            if let userName = session.user?.name, !userName.isEmpty {
                                Text(userName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(preferences.palette.textPrimary)
                                    .lineLimit(1)
                            } else {
                                Text(ShellStrings.guest)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(preferences.palette.textPrimary)
                            }
                            Text(ShellStrings.account)
                                .font(.caption)
                                .foregroundStyle(preferences.palette.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button {
                    presentedSheet = .settings
                    dismissCompactSidebar()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(preferences.palette.textSecondary)
                .accessibilityLabel(Text(ShellStrings.settings))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(preferences.palette.sidebar)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }

    private var filteredConversations: [ChatSummary] {
        let productChats = chatStore.conversations.filter { conversation in
            switch selectedProduct {
            case .ai: !conversation.agent && !conversation.codeProj && !conversation.brainNb
            case .agent: conversation.agent
            case .code: conversation.codeProj
            case .brain: conversation.brainNb
            }
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return productChats }
        return productChats.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var sidebarAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .snappy(duration: 0.28, extraBounce: 0)
    }

    private func selectProduct(_ product: ProductKind) {
        selectedProduct = product
        dismissCompactSidebar()
    }

    private func selectConversation(_ id: String) {
        dismissCompactSidebar()
        Task {
            await chatStore.select(id)
        }
    }

    private func createConversation() {
        selectedProduct = .ai
        dismissCompactSidebar()
        Task {
            await chatStore.new()
        }
    }

    private func dismissCompactSidebar() {
        guard isCompact else { return }
        withAnimation(sidebarAnimation) {
            compactSidebarPresented = false
        }
    }

    private func closeSidebar() {
        if isCompact {
            dismissCompactSidebar()
        } else {
            onCloseSidebar?()
        }
    }
}

private struct ProductSidebarRow: View {
    let product: ProductKind
    let isSelected: Bool

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        SidebarSelectionSurface(isSelected: isSelected) {
            HStack(spacing: 12) {
                Image(systemName: ShellStrings.productSystemImage(product))
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30, height: 30)
                    .foregroundStyle(isSelected ? preferences.palette.accent : preferences.palette.textSecondary)
                    .background(
                        isSelected
                            ? preferences.palette.accent.opacity(0.12)
                            : preferences.palette.surfaceSunken.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .accessibilityHidden(true)

                Text(ShellStrings.productTitle(product))
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ConversationSidebarRow: View {
    let conversation: ChatSummary
    let isSelected: Bool

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        SidebarSelectionSurface(isSelected: isSelected) {
            HStack(spacing: 11) {
                Image(systemName: conversation.pinned ? "pin.fill" : "bubble.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(
                        conversation.pinned ? preferences.palette.accent : preferences.palette.textMuted
                    )
                    .accessibilityHidden(true)

                Text(conversation.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct SidebarSelectionSurface<Content: View>: View {
    let isSelected: Bool
    let content: Content

    init(isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    var body: some View {
        if isSelected {
            GlassSurface(cornerRadius: 14, tintStrength: 0.065) {
                content
            }
        } else {
            content
        }
    }
}
