//
//  EmojiText.swift
//  EmojiText
//
//  Created by David Walter on 11.01.23.
//

import SwiftUI
import Nuke
import os

/// Markdown formatted Text with support for custom emojis
///
/// Custom Emojis are in the format `:emoji:`.
/// Supports local and remote custom emojis.
/// Remote emojis are resolved using [Nuke](https://github.com/kean/Nuke)
public struct EmojiText: View {
    @Environment(\.emojiImagePipeline) var imagePipeline
    @Environment(\.placeholderEmoji) var placeholderEmoji
    @Environment(\.font) var font
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    
    @ScaledMetric
    var scaleFactor: CGFloat = 1.0
    
    let raw: String
    let isMarkdown: Bool
    let emojis: [any CustomEmoji]
    
    var prepend: (() -> Text)?
    var append: (() -> Text)?
    
    @State private var renderedEmojis = [String: RenderedEmoji]()
    @State private var isLoading = true
    
    let logger = Logger()
    
    public var body: some View {
        ZStack {
            if !isLoading {
                rendered
            }
        }
        .task {
            defer { isLoading = false }
            guard !emojis.isEmpty else { return }
            
            // Set placeholders
            self.renderedEmojis = loadPlaceholders()
            self.isLoading = false
            
            // Load actual emojis
            self.renderedEmojis = await loadEmojis()
        }
    }
    
    var targetSize: CGSize {
        let font = EmojiFont.preferredFont(from: self.font, for: self.dynamicTypeSize)
        let height = font.capHeight * scaleFactor
        return CGSize(width: height, height: height)
    }
    
    func loadPlaceholders() -> [String: RenderedEmoji] {
        let targetSize = self.targetSize
        
        var placeholders = [String: RenderedEmoji]()
        
        for emoji in emojis {
            switch emoji {
            case let localEmoji as LocalEmoji:
                placeholders[emoji.shortcode] = RenderedEmoji(from: localEmoji, targetSize: targetSize)
            case let sfSymbolEmoji as SFSymbolEmoji:
                placeholders[emoji.shortcode] = RenderedEmoji(from: sfSymbolEmoji)
            default:
                placeholders[emoji.shortcode] = RenderedEmoji(placeholder: placeholderEmoji, targetSize: targetSize)
            }
        }
        
        return placeholders
    }
    
    func loadEmojis() async -> [String: RenderedEmoji] {
        let targetSize = self.targetSize
        
        var renderedEmojis = [String: RenderedEmoji]()
        
        for emoji in emojis {
            switch emoji {
            case let remoteEmoji as RemoteEmoji:
                do {
                    let response = try await imagePipeline.image(for: remoteEmoji.url)
                    renderedEmojis[emoji.shortcode] = RenderedEmoji(from: remoteEmoji, image: response.image, targetSize: targetSize)
                } catch {
                    logger.error("Unable to load remote emoji \(remoteEmoji.shortcode): \(error.localizedDescription)")
                }
            case let localEmoji as LocalEmoji:
                renderedEmojis[emoji.shortcode] = RenderedEmoji(from: localEmoji, targetSize: targetSize)
            case let sfSymbolEmoji as SFSymbolEmoji:
                renderedEmojis[emoji.shortcode] = RenderedEmoji(from: sfSymbolEmoji)
            default:
                // Fallback to placeholder emoji
                logger.warning("Tried to load unknown emoji. Falling back to placeholder emoji")
                renderedEmojis[emoji.shortcode] = RenderedEmoji(placeholder: placeholderEmoji, targetSize: targetSize)
            }
        }
        
        return renderedEmojis
    }
    
    /// Initialize a Markdown formatted Text with support for custom emojis
    ///
    /// - Parameters:
    ///     - markdown: Markdown formatted text to render
    ///     - emojis: Array of custom emojis to render
    public init(markdown: String, emojis: [any CustomEmoji]) {
        self.raw = markdown
        self.isMarkdown = true
        self.emojis = emojis
    }
    
    /// Initialize a ``EmojiText`` with support for custom emojis
    ///
    /// - Parameters:
    ///     - verbatim: A string to display without localization.
    ///     - emojis: Array of custom emojis to render
    public init(verbatim: String, emojis: [any CustomEmoji]) {
        self.raw = verbatim
        self.isMarkdown = false
        self.emojis = emojis
    }
    
    // MARK: - Modifier
    
    /// Prepend `Text` to the `EmojiText`
    ///
    /// - Parameter text: Callback generating the text to prepend
    /// - Returns: ``EmojiText`` with some text prepended
    public func prepend(text: @escaping () -> Text) -> Self {
        var view = self
        view.prepend = text
        return view
    }
    
    /// Append `Text` to the `EmojiText`
    ///
    /// - Parameter text: Callback generating the text to append
    /// - Returns: ``EmojiText`` with some text appended
    public func append(text: @escaping () -> Text) -> Self {
        var view = self
        view.append = text
        return view
    }
    
    // MARK: - Helper
    
    var preRendered: String {
        var text = raw
        
        for shortcode in renderedEmojis.keys {
            text = text.replacingOccurrences(of: ":\(shortcode):", with: "\(String.emojiSeparator)\(shortcode)\(String.emojiSeparator)")
        }
        
        return text
    }
    
    var rendered: Text {
        var result = prepend?() ?? Text(verbatim: "")
        
        if renderedEmojis.isEmpty {
            if isMarkdown {
                result = result + Text(attributedString(from: preRendered))
            } else {
                result = result + Text(verbatim: preRendered)
            }
        } else {
            let splits: [String]
            if #available(iOS 16, macOS 13, tvOS 16, *) {
                splits = preRendered
                    .split(separator: String.emojiSeparator, omittingEmptySubsequences: true)
                    .map { String($0) }
            } else {
                splits = preRendered
                    .components(separatedBy: String.emojiSeparator)
            }
            splits.forEach { substring in
                if let image = renderedEmojis[substring] {
                    result = result + Text("\(image.image)")
                } else if isMarkdown {
                    result = result + Text(attributedString(from: substring))
                } else {
                    result = result + Text(verbatim: String(substring))
                }
            }
        }
        
        if let append = self.append {
            result = result + append()
        }
        
        return result
    }
    
    func attributedString(from string: String) -> AttributedString {
        do {
            let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true,
                                                                  interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return try AttributedString(markdown: string, options: options)
        } catch {
            logger.error("Unable to parse Markdown, falling back to raw string: \(error.localizedDescription)")
            return AttributedString(stringLiteral: string)
        }
    }
}

struct EmojiText_Previews: PreviewProvider {
    static var emojis: [any CustomEmoji] {
        [
            RemoteEmoji(shortcode: "mastodon", url: URL(string: "https://files.mastodon.social/custom_emojis/images/000/003/675/original/089aaae26a2abcc1.png")!),
            SFSymbolEmoji(shortcode: "iphone")
        ]
    }
    
    static var previews: some View {
        List {
            Section {
                EmojiText(verbatim: "Hello World :mastodon: with a remote emoji",
                          emojis: emojis)
                EmojiText(verbatim: "Hello World :iphone: with a local emoji",
                          emojis: emojis)
                EmojiText(verbatim: "Hello World :mastodon: with a remote emoji",
                          emojis: emojis)
                .font(.title)
                EmojiText(verbatim: "Large Image as Emoji :large:",
                          emojis: [RemoteEmoji(shortcode: "large", url: URL(string: "https://sample-videos.com/img/Sample-jpg-image-15mb.jpeg")!)])
            } header: {
                Text("Text")
            }
            
            Section {
                EmojiText(markdown: "**Hello** *World* :mastodon: with a remote emoji",
                          emojis: emojis)
                EmojiText(markdown: "**Hello** *World* :mastodon: :test: with a remote emoji and a fake emoji",
                          emojis: emojis)
                EmojiText(markdown: "**Hello** *World* :mastodon: :iphone: with a remote and a local emoji",
                          emojis: emojis)
                EmojiText(markdown: "**Hello** *World* :test: with a remote emoji that will not respond properly",
                          emojis: [RemoteEmoji(shortcode: "test", url: URL(string: "about:blank")!)])
                EmojiText(markdown: "**Hello** *World* :notAnEmoji: with no emojis",
                          emojis: [])
                
                EmojiText(markdown: "**Hello** *World* :mastodon:",
                          emojis: emojis)
                .prepend {
                    Text("Prepended - ")
                }
                .append {
                    Text(" - Appended")
                }
            } header: {
                Text("Markdown")
            }
        }
        .environment(\.emojiImagePipeline, ImagePipeline { configuration in
            configuration.imageCache = nil
            configuration.dataCache = nil
        })
    }
}
