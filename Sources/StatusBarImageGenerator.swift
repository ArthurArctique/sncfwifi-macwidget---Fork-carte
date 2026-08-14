import Cocoa

class StatusBarImageGenerator {
    /// Largeur maximale de la pastille (px). Au-delà, le texte est tronqué avec « … ».
    /// Borner la largeur évite que macOS masque complètement l'élément quand la barre
    /// de menus est encombrée (notamment avec l'encoche des MacBook récents).
    static let maxWidth: CGFloat = 150

    /// Génère une image pour la barre de menu avec le texte au-dessus et une jauge en dessous.
    /// - Parameters:
    ///   - text: Le texte à afficher (ex: "Paris 12min · 300km/h")
    ///   - progress: La progression (de 0.0 à 1.0)
    ///   - maxWidth: Largeur maximale de la pastille ; le texte est tronqué au-delà.
    ///   - minWidth: Largeur minimale ; la pastille est complétée à droite, le texte restant calé
    ///     à gauche. Sert à figer la largeur de l'élément de barre quand le texte alterne, pour
    ///     que le bouton — et le popover qui s'y ancre — ne se déplacent pas.
    static func draw(text: String,
                     progress: Double,
                     maxWidth: CGFloat = StatusBarImageGenerator.maxWidth,
                     minWidth: CGFloat = 0) -> NSImage? {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)

        // Troncature en fin de ligne (« … ») si le texte dépasse la largeur autorisée.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black, // Sera transformé par isTemplate
            .paragraphStyle: paragraph
        ]

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let naturalSize = attributedString.size()

        let marginX: CGFloat = 4
        // Largeur de texte disponible, plafonnée.
        let maxTextWidth = max(0, maxWidth - marginX * 2)
        let textWidth = min(naturalSize.width, maxTextWidth)
        let width = max(textWidth + (marginX * 2), minWidth)
        let height: CGFloat = 22 // Hauteur standard

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        // 1. Dessiner le texte (tronqué si nécessaire), décalé vers le haut pour laisser place à la barre
        let textY: CGFloat = 6
        let textRect = NSRect(x: marginX, y: textY, width: textWidth, height: naturalSize.height)
        attributedString.draw(in: textRect)

        // 2. Dessiner la barre de fond
        // Sur toute la largeur utile, et non sur celle du texte : sans quoi la jauge changerait de
        // longueur à chaque bascule du titre, alors que la pastille est justement figée pour ne
        // plus bouger. Sans `minWidth`, les deux valeurs sont égales et le rendu est inchangé.
        let barWidth = width - (marginX * 2)
        let barHeight: CGFloat = 2.5
        let barY: CGFloat = 2
        
        let bgPath = NSBezierPath(roundedRect: NSRect(x: marginX, y: barY, width: barWidth, height: barHeight), xRadius: barHeight/2, yRadius: barHeight/2)
        NSColor.black.withAlphaComponent(0.3).setFill()
        bgPath.fill()
        
        // 3. Dessiner la jauge remplie
        let clampedProgress = CGFloat(max(0.0, min(1.0, progress)))
        let progressW = barWidth * clampedProgress
        
        if progressW > 0 {
            let fgPath = NSBezierPath(roundedRect: NSRect(x: marginX, y: barY, width: progressW, height: barHeight), xRadius: barHeight/2, yRadius: barHeight/2)
            NSColor.black.setFill()
            fgPath.fill()
        }
        
        // 4. Dessiner le "pouce" (le point de progression)
        let thumbRadius: CGFloat = 3.0
        // Centré verticalement sur la barre, positionné à la fin de la jauge
        // On s'assure qu'il ne déborde pas trop
        var thumbX = marginX + progressW - thumbRadius
        if thumbX < marginX - thumbRadius { thumbX = marginX - thumbRadius }
        if thumbX > marginX + barWidth - thumbRadius { thumbX = marginX + barWidth - thumbRadius }
        
        let thumbRect = NSRect(x: thumbX, y: barY + (barHeight/2) - thumbRadius, width: thumbRadius * 2, height: thumbRadius * 2)
        
        let thumbPath = NSBezierPath(ovalIn: thumbRect)
        NSColor.black.setFill()
        thumbPath.fill()
        
        image.unlockFocus()
        
        // Permet à l'icône de s'adapter automatiquement au Dark / Light mode de macOS
        image.isTemplate = true
        
        return image
    }
}
