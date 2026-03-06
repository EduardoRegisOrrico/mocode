import SwiftUI
import UIKit

struct BrandLogo: View {
    var size: CGFloat

    private var logoImage: UIImage? {
        UIImage(named: "mocode_brand_mark")
    }

    var body: some View {
        if let logoImage {
            Image(uiImage: logoImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text("mocode")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .foregroundColor(MocodeTheme.accent)
        }
    }
}

// MARK: - Previews

#Preview("Small") {
    BrandLogo(size: 48)
}

#Preview("Medium") {
    BrandLogo(size: 86)
}

#Preview("Large") {
    BrandLogo(size: 112)
}
