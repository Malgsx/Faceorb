import AppKit
import SwiftUI

/// Phone access: a switch, and while it's on, the QR code a phone scans to open FaceOrb and add
/// it to its home screen.
struct PhoneView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { model.phoneAccessEnabled }, set: { model.phoneAccessEnabled = $0 })) {
                Text("Open FaceOrb on your phone").font(.headline)
            }
            .toggleStyle(.switch)

            if model.phoneAccessEnabled {
                if let phone = model.phoneLink(), let url = phone.url,
                   let png = phone.qrPNG, let qr = NSImage(data: png) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 190, height: 190)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("QR code for the phone link")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Scan the code with your phone's camera (same Wi-Fi as this Mac).")
                        Text("2. Add it to your home screen: Share, then Add to Home Screen on iPhone; ⋮, then Add to Home screen on Android.")
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(url).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                        .controlSize(.small)
                    }
                } else {
                    Label("This Mac isn't on a network. Connect to Wi-Fi to get a link.", systemImage: "wifi.slash")
                        .font(.callout)
                }
            }

            Text("Phones need the key in the code to get in, but the connection isn't encrypted, so only turn this on at home or on other networks you trust. Photos are still analysed on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}
