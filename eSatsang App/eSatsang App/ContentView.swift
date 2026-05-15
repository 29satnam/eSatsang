import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoggedIn {
                    PlayView(viewModel: viewModel)
                } else {
                    LoginView(viewModel: viewModel)
                }
            }
            .navigationTitle("eSatsang")
        }
        .navigationViewStyle(.stack)
        .alert(viewModel.alertTitle, isPresented: $viewModel.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.alertMessage)
        }
    }
}
