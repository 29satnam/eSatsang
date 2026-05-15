import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    enum Field { case username, password }

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                    .accessibilityLabel("Username")

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { login() }
                    .accessibilityLabel("Password")
            }

            Section {
                Button {
                    login()
                } label: {
                    if viewModel.isBusy {
                        ProgressView()
                    } else {
                        Text("Login")
                    }
                }
                .disabled(!canLogin || viewModel.isBusy)
                .accessibilityHint("Validates your eSatsang login and remembers it on this device.")
            }
        }
        .navigationTitle("Login")
        .onAppear {
            username = viewModel.savedUsername ?? ""
            focusedField = username.isEmpty ? .username : .password
        }
    }

    private var canLogin: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func login() {
        Task { await viewModel.login(username: username, password: password) }
    }
}
