import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pantherPatch = UTType(importedAs: "com.pantherkeygarden.patch3105", conformingTo: .data)
}
import Security

struct AdminKey: Decodable, Identifiable, Hashable {
    let id: String
    let code: String
    let label: String
    let expires_at: String?
    let permanent: Bool
    let revoked: Bool
    let device_bound: Bool
    let active: Bool
    let revision: Int
    let device_name: String?
    let device_model: String?
    let ios_version: String?
}
// Los nombres personalizados se conservan en este dispositivo, sin modificar las keys.
private enum KeyOwnerNames {
    private static let storageKey = "panther.admin.keyOwnerNames.v1"
    static func name(for key: AdminKey) -> String {
        let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        return saved[key.code] ?? key.label
    }
    static func save(_ name: String, for key: AdminKey) {
        var saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { saved.removeValue(forKey: key.code) }
        else { saved[key.code] = cleaned }
        UserDefaults.standard.set(saved, forKey: storageKey)
    }
}

struct AdminPatch: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let version: Int
    let expires_at: String?
}
struct PatchAssignment: Encodable { let patch_id: String }
struct KeyCreation: Encodable { let label: String; let days: Int? }
struct KeyUpdate: Encodable { let action: String; let days: Int?; let hours: Int?; let minutes: Int? }

private enum AdminTokenStore {
    private static let service = "com.pantherkeygarden.admin"
    private static let account = "render-admin-token"
    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }
    static func save(_ token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if token.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

struct ResellerAccount: Decodable, Identifiable {
    let id: String
    let username: String
    let balance: Int
    let enabled: Bool
}
private struct ResellerAccountCard: View {
    @ObservedObject var api: AdminAPI
    let reseller: ResellerAccount
    let onDelete: () -> Void
    @State private var adjustment = ""
    @State private var total = ""

    var body: some View {
        NeonPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(reseller.username).font(.headline)
                        Text(reseller.enabled ? "ACTIVO" : "SUSPENDIDO")
                            .font(.caption).foregroundStyle(reseller.enabled ? .green : .orange)
                    }
                    Spacer()
                    Text("\(reseller.balance) créditos").bold()
                }
                HStack {
                    TextField("Cantidad (+ o -)", text: $adjustment)
                        .keyboardType(.numbersAndPunctuation).pantherInput()
                    Button("Aplicar ajuste") {
                        guard let amount = Int(adjustment), amount != 0 else { return }
                        Task {
                            if await api.changeResellerBalance(reseller.id, adjustment: .delta(amount)) {
                                adjustment = ""
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((Int(adjustment) ?? 0) == 0)
                }
                HStack {
                    TextField("Nuevo saldo total", text: $total)
                        .keyboardType(.numberPad).pantherInput()
                    Button("Fijar saldo") {
                        guard let amount = Int(total), amount >= 0 else { return }
                        Task {
                            if await api.changeResellerBalance(reseller.id, adjustment: .total(amount)) {
                                total = ""
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((Int(total) ?? -1) < 0)
                }
                ResellerPatchPanel(api: api, reseller: reseller)
                Button(reseller.enabled ? "Suspender cuenta" : "Activar cuenta") {
                    Task { await api.setResellerEnabled(reseller.id, enabled: !reseller.enabled) }
                }
                .foregroundStyle(reseller.enabled ? .orange : .green)
                Button(role: .destructive, action: onDelete) {
                    Label("Eliminar cuenta", systemImage: "trash")
                }
                .foregroundStyle(.red)
            }
            .disabled(api.updatingReseller)
        }
    }
}

private struct ResellerPatchPanel: View {
    @ObservedObject var api: AdminAPI
    let reseller: ResellerAccount
    @State private var granted: Set<String> = []
    @State private var loading = false
    @State private var grantDays = 30
    @State private var expirations: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PATCHES AUTORIZADOS").font(.caption.bold())
            Picker("Duración del permiso", selection: $grantDays) {
                Text("1 día").tag(1)
                Text("5 días").tag(5)
                Text("30 días").tag(30)
                Text("90 días").tag(90)
            }.pickerStyle(.menu)
            Button("Eliminar patches vencidos") {
                Task { await api.cleanupExpiredResellerPatches(reseller.id); await reload() }
            }.buttonStyle(.bordered)
            Text("Los permisos vencidos también se retiran automáticamente al consultar o usar un patch.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(api.patches) { patch in
                HStack {
                    VStack(alignment: .leading) {
                        Text(patch.name).font(.subheadline)
                        Text(patch.category).font(.caption2).foregroundStyle(.secondary)
                        if let expiry = expirations[patch.id] {
                            Text("Vence: \(expiry.prefix(10))").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(granted.contains(patch.id) ? "Quitar acceso" : "Autorizar") {
                        Task {
                            await api.setResellerPatch(reseller.id, patchID: patch.id, grant: !granted.contains(patch.id), days: grantDays)
                            await reload()
                        }
                    }.buttonStyle(.bordered).disabled(loading)
                }
            }
            if api.patches.isEmpty { Text("Sube primero tus patches en el menú Patches.").font(.caption) }
        }.task { await reload() }
    }
    private func reload() async {
        loading = true
        let items = await api.resellerGrantedPatches(reseller.id)
        granted = Set(items.map(\.id))
        expirations = Dictionary(uniqueKeysWithValues: items.compactMap { patch in
            patch.expires_at.map { (patch.id, $0) }
        })
        loading = false
    }
}

enum ResellerBalanceAdjustment {
    case delta(Int)
    case total(Int)
}

private struct ResellerCreateBody: Encodable { let username: String; let password: String }
private struct ResellerBalanceBody: Encodable { let delta: Int }
private struct ResellerStatusBody: Encodable { let enabled: Bool }
private struct ResellerPriceBody: Encodable { let credits: Int }

@MainActor final class AdminAPI: ObservableObject {
    @Published var server: String = UserDefaults.standard.string(forKey: "panther.admin.server") ?? "" {
        didSet { UserDefaults.standard.set(server, forKey: "panther.admin.server") }
    }
    @Published var token: String = AdminTokenStore.load() {
        didSet { AdminTokenStore.save(token) }
    }
    @Published var keys: [AdminKey] = []
    @Published var patches: [AdminPatch] = []
    @Published var resellers: [ResellerAccount] = []
    @Published private(set) var updatingReseller = false
    @Published var message = "Configura tu servidor HTTPS y token de administrador."
    @Published var busy = false
    private func url(_ path: String) throws -> URL {
        guard server.hasPrefix("https://"), let url = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw NSError(domain:"Configura una URL HTTPS válida",code:1) }
        return url
    }
    func send(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var req = URLRequest(url:try url(path))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization")
        if let body {
            req.setValue("application/json",forHTTPHeaderField:"Content-Type")
            req.httpBody = body
        }
        let (data,response) = try await URLSession.shared.data(for:req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain:"Error del servidor: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)",code:2)
        }
        return data
    }
    func sendJSON<T: Encodable>(_ path: String, method: String, body: T) async throws -> Data {
        try await send(path, method:method, body:JSONEncoder().encode(body))
    }
    func resellerGrantedPatches(_ id: String) async -> [AdminPatch] {
        do { return try JSONDecoder().decode([AdminPatch].self, from: try await send("/admin/resellers/\(id)/patches")) }
        catch { message = "No se pudieron cargar los patches: \(error.localizedDescription)"; return [] }
    }
    func setResellerPatch(_ id: String, patchID: String, grant: Bool, days: Int = 30) async {
        do {
            let body: Data? = grant ? try JSONSerialization.data(withJSONObject: ["days": days]) : nil
            _ = try await send("/admin/resellers/\(id)/patches/\(patchID)", method: grant ? "POST" : "DELETE", body: body)
            message = grant ? "Patch autorizado al revendedor." : "Acceso al patch retirado."
        } catch { message = "Error de permisos: \(error.localizedDescription)" }
    }
    func cleanupExpiredResellerPatches(_ id: String) async {
        do {
            _ = try await send("/admin/resellers/\(id)/patches/cleanup-expired", method: "POST")
            message = "Permisos de patches vencidos eliminados."
        } catch { message = "Error al limpiar permisos: \(error.localizedDescription)" }
    }
    private func refreshResellers() async throws {
        let data = try await send("/admin/resellers")
        resellers = try JSONDecoder().decode([ResellerAccount].self, from: data)
    }
    func loadResellers() async {
        do { try await refreshResellers() }
        catch { message = "Revendedores: \(error.localizedDescription)" }
    }
    func createReseller(username: String, password: String) async {
        do {
            _ = try await sendJSON("/admin/resellers", method: "POST", body: ResellerCreateBody(username: username, password: password))
            message = "Cuenta de revendedor creada."
            await loadResellers()
        } catch { message = "No se pudo crear: \(error.localizedDescription)" }
    }
    func changeResellerBalance(_ id: String, adjustment: ResellerBalanceAdjustment) async -> Bool {
        guard !updatingReseller else { return false }
        updatingReseller = true
        defer { updatingReseller = false }

        let delta: Int
        do {
            switch adjustment {
            case .delta(let amount):
                delta = amount
            case .total(let total):
                try await refreshResellers()
                guard let account = resellers.first(where: { $0.id == id }) else {
                    message = "La cuenta ya no está disponible."
                    return false
                }
                let result = total.subtractingReportingOverflow(account.balance)
                guard total >= 0, !result.overflow else {
                    message = "El nuevo saldo está fuera del rango permitido."
                    return false
                }
                delta = result.partialValue
            }

            if delta != 0 {
                _ = try await sendJSON("/admin/resellers/\(id)/balance", method: "POST", body: ResellerBalanceBody(delta: delta))
            }
        } catch {
            message = "No se pudo confirmar el cambio de saldo: \(error.localizedDescription)"
            return false
        }

        do {
            if delta != 0 { try await refreshResellers() }
            guard let account = resellers.first(where: { $0.id == id }) else {
                message = "El servidor aceptó el ajuste, pero la cuenta ya no está disponible."
                return true
            }
            if case .total(let requested) = adjustment, requested != account.balance {
                message = "\(account.username) tiene \(account.balance) créditos. Se solicitó un total de \(requested)."
            } else {
                message = "\(account.username) tiene \(account.balance) créditos."
            }
        } catch {
            message = "El servidor aceptó el ajuste. Pulsa Actualizar para consultar el saldo."
        }
        return true
    }
    func deleteReseller(_ account: ResellerAccount) async {
        guard !updatingReseller else { return }
        updatingReseller = true
        defer { updatingReseller = false }

        do {
            _ = try await send("/admin/resellers/\(account.id)", method: "DELETE")
            resellers.removeAll { $0.id == account.id }
            message = "Cuenta \(account.username) eliminada."
            await loadResellers()
        } catch {
            message = "No se pudo confirmar la eliminación de \(account.username): \(error.localizedDescription)"
        }
    }
    func setResellerEnabled(_ id: String, enabled: Bool) async {
        do {
            _ = try await sendJSON("/admin/resellers/\(id)/status", method: "POST", body: ResellerStatusBody(enabled: enabled))
            message = enabled ? "Cuenta activada." : "Cuenta suspendida."
            await loadResellers()
        } catch { message = "No se pudo cambiar el estado: \(error.localizedDescription)" }
    }
    func setResellerPrice(days: Int, credits: Int) async {
        do {
            _ = try await sendJSON("/admin/reseller-prices/\(days)", method: "PUT", body: ResellerPriceBody(credits: credits))
            message = "Precio de \(days) días actualizado."
        } catch { message = "No se pudo cambiar el precio: \(error.localizedDescription)" }
    }
    func reload() async {
        busy = true; defer { busy = false }
        do {
            async let k = send("/admin/keys")
            async let p = send("/admin/patches")
            keys = try JSONDecoder().decode([AdminKey].self, from: await k)
            patches = try JSONDecoder().decode([AdminPatch].self, from: await p)
            message = "Conectado. \(keys.count) keys · \(patches.count) patches."
        } catch { message = error.localizedDescription }
    }
    func create(days: Int?, label: String) async {
        do { _ = try await sendJSON("/admin/keys",method:"POST",body:KeyCreation(label:label,days:days)); await reload() }
        catch { message = error.localizedDescription }
    }
    func update(_ key: AdminKey, action: String, days: Int? = nil, hours: Int? = nil, minutes: Int? = nil) async {
        do { _ = try await sendJSON("/admin/keys/\(key.id)/change",method:"POST",body:KeyUpdate(action:action,days:days,hours:hours,minutes:minutes)); await reload() }
        catch { message = error.localizedDescription }
    }
    func delete(_ key: AdminKey) async {
        do { _ = try await send("/admin/keys/\(key.id)",method:"DELETE"); await reload() }
        catch { message = error.localizedDescription }
    }
    func assignments(_ key: AdminKey) async -> [AdminPatch] {
        do { return try JSONDecoder().decode([AdminPatch].self,from:await send("/admin/keys/\(key.id)/patches")) }
        catch { message = error.localizedDescription; return [] }
    }
    func assign(_ patch: AdminPatch, key: AdminKey) async {
        do { _ = try await sendJSON("/admin/keys/\(key.id)/patches",method:"POST",body:PatchAssignment(patch_id:patch.id)); await reload() }
        catch { message = error.localizedDescription }
    }
    func unassign(_ patch: AdminPatch, key: AdminKey) async {
        do { _ = try await send("/admin/keys/\(key.id)/patches/\(patch.id)",method:"DELETE"); await reload() }
        catch { message = error.localizedDescription }
    }
    func deletePatch(_ patch: AdminPatch) async {
        do { _ = try await send("/admin/patches/\(patch.id)", method: "DELETE"); await reload() }
        catch { message = error.localizedDescription }
    }
    func all(_ patch: AdminPatch, remove: Bool) async {
        do {
            _ = try await send("/admin/patches/\(patch.id)/all",method:remove ? "DELETE" : "POST")
            await reload()
        } catch { message = error.localizedDescription }
    }
    func upload(_ file: URL, name: String, category: String, replace: AdminPatch? = nil) async {
        busy = true; defer { busy = false }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let data = try Data(contentsOf: file)
            guard file.pathExtension.lowercased() == "3105", !data.isEmpty, data.count <= 20*1024*1024 else {
                message = "Selecciona un archivo .3105 de hasta 20 MB."; return
            }
            let path = replace.map { "/admin/patches/\($0.id)" } ?? "/admin/patches"
            var components = URLComponents(url: try url(path), resolvingAgainstBaseURL: false)!
            if replace == nil {
                components.queryItems = [URLQueryItem(name: "name", value: name.trimmingCharacters(in: .whitespacesAndNewlines)), URLQueryItem(name: "category", value: category)]
            }
            let boundary = UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"patch.3105\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var req = URLRequest(url: components.url!)
            req.httpMethod = replace == nil ? "POST" : "PUT"
            req.timeoutInterval = 90
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (responseData, response) = try await URLSession.shared.upload(for: req, from: body)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let detail = String(data: responseData, encoding: .utf8) ?? "Sin detalles"
                message = "Error al subir: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) · \(detail.prefix(240))"
                return
            }
            await reload()
            message = replace == nil ? "Patch subido al servidor. Asígnalo a una key o a todos." : "Archivo reemplazado correctamente."
        } catch { message = "Error al subir archivo: \(error.localizedDescription)" }
    }
}

@main struct PantherAdminApp: App {
    var body: some Scene { WindowGroup { AdminHome() } }
}


private enum PantherStyle {
    static let bg = Color(red: 0.005, green: 0.014, blue: 0.04)
    static let panel = Color(red: 0.015, green: 0.045, blue: 0.10)
    static let blue = Color(red: 0.02, green: 0.64, blue: 1)
    static let pale = Color(red: 0.72, green: 0.84, blue: 1)
}

private struct NeonPanel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(PantherStyle.panel))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(PantherStyle.blue.opacity(0.85), lineWidth: 1.2))
            .shadow(color: PantherStyle.blue.opacity(0.15), radius: 9)
    }
}

private struct NeonButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [.blue, PantherStyle.blue], startPoint: .bottom, endPoint: .top))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct MenuTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: icon).font(.system(size: 27)).foregroundStyle(PantherStyle.blue).frame(width: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(PantherStyle.pale)
                }
                Spacer(minLength: 3)
                Image(systemName: "chevron.right").foregroundStyle(PantherStyle.pale)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(PantherStyle.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(PantherStyle.blue, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private enum AdminTab: String, CaseIterable {
    case home = "Inicio", keys = "Keys", patches = "Patches", resellers = "Revendedores", activity = "Actividad", settings = "Ajustes"
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .keys: return "key.fill"
        case .patches: return "square.stack.3d.up.fill"
        case .resellers: return "person.2.fill"
        case .activity: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }
}


/// Selector nativo de iOS: se presenta como hoja independiente del NavigationStack.
private struct PantherDocumentPicker: UIViewControllerRepresentable {
    let onPick: (Result<URL, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Result<URL, Error>) -> Void
        init(onPick: @escaping (Result<URL, Error>) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(.success(url)) }
        }
    }
}

struct AdminHome: View {
    @StateObject private var api = AdminAPI()
    @State private var tab: AdminTab = .home
    @State private var resellerUsername = ""
    @State private var resellerPassword = ""
    @State private var resellerToDelete: ResellerAccount?
    @State private var resellerPrices: [Int: String] = [1:"1",5:"3",30:"10"]
    @State private var label = ""
    @State private var days = 30
    @State private var permanent = false
    @State private var category = "Head"
    @State private var patchName = ""
    @State private var importing = false
    @State private var replacePatch: AdminPatch?
    @State private var connected = false
    @State private var showToken = false
    @State private var showDevices = false
    @State private var showVersions = false
    @State private var showAllPatches = false
    @State private var patchToDelete: AdminPatch?
    @State private var patchForKey: AdminPatch?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 15) {
                        if tab == .home { homeContent }
                        if tab == .keys { keysContent }
                        if tab == .patches { patchesContent }
                        if tab == .resellers { resellerContent }
                        if tab == .activity { activityContent }
                        if tab == .settings { settingsContent }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 0)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .scrollIndicators(.hidden)
                tabBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                ZStack {
                    PantherStyle.bg.ignoresSafeArea()
                    Image("PantherAdminAtmosphere").resizable().scaledToFill().ignoresSafeArea().opacity(0.13).allowsHitTesting(false)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $importing) {
                PantherDocumentPicker { result in
                    importing = false
                    switch result {
                    case .success(let file):
                        guard file.pathExtension.lowercased() == "3105" else {
                            api.message = "Selecciona un archivo con extensión .3105."
                            return
                        }
                        let access = file.startAccessingSecurityScopedResource()
                        defer { if access { file.stopAccessingSecurityScopedResource() } }
                        do {
                            let copy = FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString)
                                .appendingPathExtension("3105")
                            try FileManager.default.copyItem(at: file, to: copy)
                            let selectedName = file.deletingPathExtension().lastPathComponent
                            patchName = selectedName
                            let selectedCategory = category
                            let selectedReplacement = replacePatch
                            Task { await api.upload(copy, name: selectedName, category: selectedCategory, replace: selectedReplacement) }
                        } catch {
                            api.message = "No se pudo leer el archivo: \\(error.localizedDescription)"
                        }
                    case .failure(let error):
                        api.message = "No se pudo seleccionar el archivo: \\(error.localizedDescription)"
                    }
                }
            }
            .onOpenURL { incomingURL in
                guard incomingURL.pathExtension.lowercased() == "3105" else {
                    api.message = "El archivo debe tener extensión .3105."
                    return
                }
                let scoped = incomingURL.startAccessingSecurityScopedResource()
                defer { if scoped { incomingURL.stopAccessingSecurityScopedResource() } }
                do {
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("3105")
                    try FileManager.default.copyItem(at: incomingURL, to: temp)
                    let incomingName = incomingURL.deletingPathExtension().lastPathComponent
                    // Importar desde Archivos envía el patch al servidor con la categoría actual.
                    // El administrador puede asignarlo después de la subida.
                    tab = .patches
                    api.message = "Importando \(incomingURL.lastPathComponent)…"
                    Task { await api.upload(temp, name: incomingName, category: category) }
                } catch {
                    api.message = "No se pudo importar el archivo: \(error.localizedDescription)"
                }
            }
            .sheet(item: $patchForKey) { patch in
                PatchKeyPicker(api: api, patch: patch)
            }
            .confirmationDialog("¿Eliminar este patch y sus asignaciones de todas las keys?", isPresented: Binding(get: { patchToDelete != nil }, set: { if !$0 { patchToDelete = nil } })) {
                if let patch = patchToDelete {
                    Button("Eliminar definitivamente", role: .destructive) {
                        patchToDelete = nil
                        Task { await api.deletePatch(patch) }
                    }
                }
                Button("Cancelar", role: .cancel) { patchToDelete = nil }
            }
            .onChange(of: api.message) { newMessage in
                connected = newMessage.hasPrefix("Conectado.")
            }
        }
        .tint(PantherStyle.blue)
    }

    private var header: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                Image("PantherAdminHeader")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .frame(height: 132)
            .accessibilityLabel("Panther Admin")
        }
    }

    private var connectionPanel: some View {
        NeonPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("CONEXIÓN DEL SERVIDOR", systemImage: "server.rack")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                Text("URL del servidor (HTTPS)").font(.caption).foregroundStyle(PantherStyle.pale)
                TextField("https://tu-servidor.com", text: $api.server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .pantherInput()
                HStack {
                    Group {
                        if showToken { TextField("Token administrador", text: $api.token) }
                        else { SecureField("Token administrador", text: $api.token) }
                    }
                    Button { showToken.toggle() } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                }
                .pantherInput()
                NeonButton(title: api.busy ? "CONECTANDO..." : "CONECTAR Y ACTUALIZAR", symbol: "link") {
                    Task { await api.reload() }
                }
                .disabled(api.busy)
            }
        }
    }

    private var statusPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(connected ? .green : .orange)
            Text(connected ? "SISTEMA EN LÍNEA" : "SIN CONEXIÓN")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(connected ? .green : .orange)
            Spacer()
            if api.busy { ProgressView().tint(PantherStyle.blue) }
        }
        .padding(14)
        .background(PantherStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(connected ? Color.green : PantherStyle.blue.opacity(0.6)))
    }

    private var homeContent: some View {
        VStack(spacing: 12) {
            header
            connectionPanel
            statusPanel
            MenuTile(title: "REVENDEDORES", subtitle: "Crear cuentas, saldo y autorizar patches", icon: "person.2.fill") { tab = .resellers }
            MenuTile(title: "ADMINISTRAR KEYS", subtitle: "Crear, editar, renovar y revocar keys", icon: "key.horizontal.fill") { tab = .keys }
            MenuTile(title: "ADMINISTRAR PATCHES", subtitle: "Subir, reemplazar y asignar archivos .3105", icon: "square.stack.3d.up.fill") { tab = .patches }
            MenuTile(title: "VERSIONES DE PATCH", subtitle: "Reemplazar archivos y consultar versiones", icon: "clock.arrow.circlepath") { tab = .patches; showVersions = true }
            MenuTile(title: "DISPOSITIVOS VINCULADOS", subtitle: "Ver y restablecer dispositivos por key", icon: "iphone") { tab = .keys; showDevices = true }
            MenuTile(title: "HISTORIAL DE ACTIVIDAD", subtitle: "Estado y registros del sistema", icon: "chart.bar.fill") { tab = .activity }
            quickKey
        }
    }

    private var quickKey: some View {
        NeonPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("CREAR KEY RÁPIDA").font(.system(size: 18, weight: .heavy))
                TextField("Etiqueta (ej: Usuario 1)", text: $label).pantherInput()
                Toggle("Key permanente", isOn: $permanent).tint(PantherStyle.blue)
                if !permanent {
                    Stepper("Duración: \(days) días", value: $days, in: 1...36500)
                }
                NeonButton(title: "GENERAR KEY", symbol: "plus.circle.fill") {
                    Task { await api.create(days: permanent ? nil : days, label: label) }
                }
                .disabled(api.busy || api.server.isEmpty || api.token.isEmpty)
            }
        }
    }

    private var keysContent: some View {
        VStack(spacing: 14) {
            sectionHeader("ADMINISTRAR KEYS", subtitle: "\(api.keys.count) keys registradas")
            quickKey
            if showDevices {
                NeonPanel {
                    Text("DISPOSITIVOS VINCULADOS").font(.headline)
                    Text("\(api.keys.filter { $0.device_bound }.count) keys con dispositivo vinculado")
                        .font(.subheadline).foregroundStyle(PantherStyle.pale)
                    Text("Selecciona una key para restablecer su dispositivo.").font(.caption)
                }
            }
            ForEach(api.keys) { key in
                NavigationLink {
                    KeyDetail(api: api, key: key)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill").foregroundStyle(PantherStyle.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(KeyOwnerNames.name(for: key).isEmpty ? "Sin nombre" : KeyOwnerNames.name(for: key))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                            Text(key.code).font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(PantherStyle.pale)
                            KeyCountdown(expiresAt: key.expires_at, permanent: key.permanent)
                                .font(.caption).foregroundStyle(PantherStyle.pale)
                            Text(key.revoked ? "Revocada" : "Activa")
                                .font(.caption).foregroundStyle(key.revoked ? .red : .green)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(15)
                    .background(PantherStyle.panel, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(PantherStyle.blue.opacity(0.7)))
                }
                .buttonStyle(.plain)
            }
            if api.keys.isEmpty { emptyNotice("Todavía no hay keys cargadas. Conecta el servidor para verlas.") }
        }
    }

    private var patchesContent: some View {
        VStack(spacing: 14) {
            sectionHeader("ADMINISTRAR PATCHES", subtitle: "Subir y enviar .3105 por key o para todos")
            NeonPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SUBIR NUEVO PATCH").font(.headline)
                    TextField("El nombre se tomará del archivo .3105", text: $patchName).pantherInput()
                        .disabled(true)
                    Picker("Categoría", selection: $category) {
                        ForEach(["Head", "Cuello", "Pecho", "Sintura"], id: \.self) { Text($0) }
                    }
                    .tint(PantherStyle.blue)
                    NeonButton(title: "SUBIR ARCHIVO .3105", symbol: "square.and.arrow.up.fill") {
                        replacePatch = nil; importing = true
                    }
                }
            }
            if showVersions { emptyNotice("Cada patch muestra su versión actual. Usa Reemplazar para publicar una versión nueva.") }
            ForEach(api.patches) { patch in
                NeonPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(patch.name).font(.headline)
                        Text("\(patch.category) · Versión \(patch.version)").font(.caption).foregroundStyle(PantherStyle.pale)
                        Button("Reemplazar archivo") { replacePatch = patch; importing = true }
                        HStack(spacing: 8) {
                            Button("Enviar a todos") { Task { await api.all(patch, remove: false) } }
                            Spacer()
                            Button("Quitar a todos", role: .destructive) { Task { await api.all(patch, remove: true) } }
                        }
                        .font(.system(size: 12, weight: .bold))
                        HStack(spacing: 12) {
                            Button("Enviar por key") { patchForKey = patch }
                                .foregroundStyle(PantherStyle.blue)
                            Spacer()
                            Button("Eliminar patch", role: .destructive) { patchToDelete = patch }
                                .foregroundStyle(.red)
                        }
                        .font(.system(size: 13, weight: .bold))
                    }
                }
            }
            if api.patches.isEmpty { emptyNotice("Catálogo vacío. Sube tu primer patch desde la app.") }
            Text("Para enviar a una sola key, entra en Keys y selecciona esa key.")
                .font(.caption).foregroundStyle(PantherStyle.pale)
        }
    }

    private var activityContent: some View {
        VStack(spacing: 14) {
            sectionHeader("ACTIVIDAD", subtitle: "Resumen del sistema")
            NeonPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Estado de conexión", systemImage: "network")
                    Text(api.message).font(.subheadline).foregroundStyle(PantherStyle.pale)
                    Divider()
                    Text("Keys: \(api.keys.count)  ·  Patches: \(api.patches.count)")
                    Text("El historial detallado requiere un endpoint de auditoría en el servidor.")
                        .font(.caption).foregroundStyle(PantherStyle.pale)
                }
            }
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 14) {
            sectionHeader("AJUSTES", subtitle: "Conexión segura del servidor")
            connectionPanel
            statusPanel
            NeonPanel {
                Text("Esta aplicación utiliza una API independiente. No está conectada a Lovable.")
                    .font(.subheadline)
                    .foregroundStyle(PantherStyle.pale)
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 22, weight: .black))
            Text(subtitle).font(.caption).foregroundStyle(PantherStyle.pale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
    }

    private func emptyNotice(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(PantherStyle.pale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(PantherStyle.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private var resellerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sectionHeader("REVENDEDORES", subtitle: "Cuentas, saldo, precios y permisos")
            NeonPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Label("CREAR CUENTA", systemImage: "person.badge.plus").font(.headline)
                    TextField("Usuario del revendedor", text: $resellerUsername)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().pantherInput()
                    SecureField("Contraseña (mínimo 12 caracteres)", text: $resellerPassword)
                        .pantherInput()
                    NeonButton(title: "CREAR REVENDEDOR", symbol: "plus.circle.fill") {
                        let username = resellerUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                        let password = resellerPassword
                        Task {
                            await api.createReseller(username: username, password: password)
                            resellerPassword = ""
                        }
                    }
                    .disabled(resellerUsername.count < 3 || resellerPassword.count < 12 || api.token.isEmpty || api.updatingReseller)
                }
            }
            NeonPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Label("PRECIOS EN CRÉDITOS", systemImage: "creditcard.fill").font(.headline)
                    ForEach([1,5,30], id: \.self) { days in
                        HStack {
                            Text("\(days) día\(days == 1 ? "" : "s")").frame(width: 88, alignment: .leading)
                            TextField("Créditos", text: Binding(get: { resellerPrices[days] ?? "" }, set: { resellerPrices[days] = $0 }))
                                .keyboardType(.numberPad).pantherInput()
                            Button("Guardar") {
                                if let price = Int(resellerPrices[days] ?? ""), price > 0 {
                                    Task { await api.setResellerPrice(days: days, credits: price) }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    Text("Los precios iniciales mostrados son ejemplos. Guarda los valores deseados.")
                        .font(.caption).foregroundStyle(PantherStyle.pale)
                }
            }
            HStack {
                Text("CUENTAS (\(api.resellers.count))").font(.headline)
                Spacer()
                Button("Actualizar") { Task { await api.loadResellers() } }
                    .disabled(api.updatingReseller)
            }
            ForEach(api.resellers) { reseller in
                ResellerAccountCard(api: api, reseller: reseller) {
                    resellerToDelete = reseller
                }
            }
            if api.resellers.isEmpty { emptyNotice("Pulsa Actualizar para cargar los revendedores.") }
            Text(api.message).font(.caption).foregroundStyle(PantherStyle.pale)
        }
        .task { if !api.server.isEmpty && !api.token.isEmpty { await api.loadResellers() } }
        .alert("Eliminar cuenta", isPresented: Binding(
            get: { resellerToDelete != nil },
            set: { if !$0 { resellerToDelete = nil } }
        ), presenting: resellerToDelete) { account in
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar definitivamente", role: .destructive) {
                Task { await api.deleteReseller(account) }
            }
        } message: { account in
            Text("¿Eliminar definitivamente la cuenta \(account.username)?")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AdminTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.symbol).font(.system(size: 20))
                        Text(item.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(tab == item ? .white : PantherStyle.pale)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(tab == item ? PantherStyle.blue.opacity(0.32) : .clear, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 3)
        .background(PantherStyle.bg)
        .overlay(alignment: .top) { Rectangle().fill(PantherStyle.blue).frame(height: 1) }
    }
}

private struct PantherInput: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14))
            .padding(12)
            .background(Color(red: 0.015, green: 0.09, blue: 0.18), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PantherStyle.blue.opacity(0.45)))
    }
}
private extension View {
    func pantherInput() -> some View { modifier(PantherInput()) }
}

private struct KeyCountdown: View {
    let expiresAt: String?
    let permanent: Bool
    private func expiry() -> Date? {
        guard let expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: expiresAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt)
    }
    private func remaining(_ date: Date) -> String {
        guard let expiry = expiry() else { return "Fecha no disponible" }
        let seconds = max(0, Int(expiry.timeIntervalSince(date)))
        if seconds == 0 { return "Vencida" }
        return "\(seconds / 86400)d \(seconds % 86400 / 3600)h \(seconds % 3600 / 60)m \(seconds % 60)s"
    }
    var body: some View {
        if permanent { Text("Permanente") }
        else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(remaining(context.date)).monospacedDigit()
            }
        }
    }
}

struct KeyDetail: View {
    @ObservedObject var api: AdminAPI
    let key: AdminKey
    @State private var days = 30
    @State private var hours = 0
    @State private var minutes = 0
    @State private var assigned: [AdminPatch] = []
    @State private var confirmDelete = false
    @State private var ownerName = ""
    @State private var nameSaved = false
    var body: some View {
        Form {
            Section("Nombre del propietario") {
                TextField("Ej: Juan Pérez", text: $ownerName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button("Guardar nombre") {
                    KeyOwnerNames.save(ownerName, for: key)
                    nameSaved = true
                }
                if nameSaved { Text("Nombre guardado en este dispositivo").font(.caption).foregroundStyle(.green) }
                Text("Puedes cambiarlo cuando quieras. No modifica el código ni la duración de la key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Key") {
                Text(key.code).textSelection(.enabled)
                KeyCountdown(expiresAt: key.expires_at, permanent: key.permanent)
                Text(key.device_bound ? "Dispositivo vinculado" : "Sin dispositivo")
                if key.device_bound {
                    LabeledContent("Nombre", value: key.device_name ?? "No disponible")
                    LabeledContent("Modelo", value: key.device_model ?? "No disponible")
                    LabeledContent("iOS", value: key.ios_version ?? "No disponible")
                }
            }
            Section("Cambiar duración") {
                Stepper("Días: \(days)", value: $days, in: 0...36500)
                Stepper("Horas: \(hours)", value: $hours, in: 0...23)
                Stepper("Minutos: \(minutes)", value: $minutes, in: 0...59)
                Text("Duración: \(days)d \(hours)h \(minutes)m")
                    .font(.caption)
                Button("Fijar desde ahora") { Task { await api.update(key, action: "set_days", days: days, hours: hours, minutes: minutes) } }
                Button("Agregar tiempo") { Task { await api.update(key, action: "extend", days: days, hours: hours, minutes: minutes) } }
                Button("Quitar tiempo") { Task { await api.update(key, action: "reduce", days: days, hours: hours, minutes: minutes) } }
                Button("Hacer permanente") { Task { await api.update(key, action: "permanent") } }
            }
            Section("Administración") {
                Button(key.revoked ? "Restaurar key" : "Revocar key") { Task { await api.update(key, action: key.revoked ? "restore" : "revoke") } }
                Button("Restablecer dispositivo") { Task { await api.update(key, action: "reset_device") } }
                Button("Eliminar key", role: .destructive) { confirmDelete = true }
            }
            Section("Patches de esta key") {
                Button("Actualizar asignaciones") { Task { assigned = await api.assignments(key) } }
                ForEach(api.patches) { patch in
                    HStack {
                        Text(patch.name)
                        Spacer()
                        let has = assigned.contains(where: { $0.id == patch.id })
                        Button(has ? "Quitar" : "Enviar") {
                            Task {
                                if has { await api.unassign(patch, key: key) }
                                else { await api.assign(patch, key: key) }
                                assigned = await api.assignments(key)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PantherStyle.bg)
        .navigationTitle("Administrar key")
        .toolbar(.visible, for: .navigationBar)
        .task {
            ownerName = KeyOwnerNames.name(for: key)
            assigned = await api.assignments(key)
        }
        .confirmationDialog("¿Eliminar definitivamente esta key?", isPresented: $confirmDelete) {
            Button("Eliminar", role: .destructive) { Task { await api.delete(key) } }
        }
    }
}


// Selector individual: consulta las asignaciones existentes y permite enviar o quitar el patch por key.
private struct PatchKeyPicker: View {
    @ObservedObject var api: AdminAPI
    let patch: AdminPatch
    @Environment(\.dismiss) private var dismiss
    @State private var assignedIDs: Set<String> = []
    @State private var loading = true
    @State private var workingKey: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Patch: \(patch.name)") {
                    Text("Selecciona la key que recibirá el patch. Las demás no se modifican.")
                        .font(.caption)
                }
                ForEach(api.keys) { key in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key.code).font(.system(.subheadline, design: .monospaced))
                            Text(key.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if workingKey == key.id { ProgressView() }
                        else {
                            Button(assignedIDs.contains(key.id) ? "Quitar" : "Enviar") {
                                Task {
                                    workingKey = key.id
                                    if assignedIDs.contains(key.id) {
                                        await api.unassign(patch, key: key)
                                    } else {
                                        await api.assign(patch, key: key)
                                    }
                                    let current = await api.assignments(key)
                                    if current.contains(where: { $0.id == patch.id }) { assignedIDs.insert(key.id) }
                                    else { assignedIDs.remove(key.id) }
                                    workingKey = nil
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(loading)
                        }
                    }
                }
            }
            .navigationTitle("Enviar por key")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() } } }
            .task {
                loading = true
                for key in api.keys {
                    let current = await api.assignments(key)
                    if current.contains(where: { $0.id == patch.id }) { assignedIDs.insert(key.id) }
                }
                loading = false
            }
        }
        .preferredColorScheme(.dark)
    }
}
