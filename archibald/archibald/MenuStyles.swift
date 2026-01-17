import SwiftUI

struct MenuActionButton: View {
  let title: String
  let systemImage: String
  var role: ButtonRole? = nil
  var action: () -> Void = {}

  var body: some View {
    Button(role: role, action: action) {
      MenuActionRow(title: title, systemImage: systemImage)
    }
    .buttonStyle(.plain)
  }
}

struct MenuActionRow: View {
  let title: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .frame(width: 18)
      Text(title)
      Spacer()
    }
    .font(.system(size: 13, weight: .medium))
    .foregroundStyle(.primary)
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity)
    .background(.white.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
  }
}
