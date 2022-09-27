//
// Copyright © 2021 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var main: Main
    @State private var isImporterPresented: Bool = false
    
    var body: some View {
        NavigationView {
            Group {
                if main.apps.isEmpty {
                    Text("No apps found.")
                        .font(.headline)
                } else {
                    List {
                        ForEach(main.apps) { app in
                            Text(app.lastPathComponent)
                                .lineLimit(1)
                        }.onDelete { indexSet in
                            deleteAll(indicies: indexSet)
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Apps")
            .toolbar {
                HStack {
                    Button(action: { isImporterPresented.toggle() }, label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .labelStyle(IconOnlyLabelStyle())
                    })
                    if !main.apps.isEmpty {
                        EditButton()
                    }
                }
            }
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.ipa, .application], onCompletion: importFile)
        }.navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func deleteAll(indicies: IndexSet) {
        var toDelete: [URL] = []
        for i in indicies {
            toDelete.append(main.apps[i])
        }
        main.backgroundTask(message: NSLocalizedString("Deleting app...", comment: "AppsView")) {
            for url in toDelete {
                try main.deleteApp(url)
            }
        } onComplete: {
            main.apps.remove(atOffsets: indicies)
        }
    }
    
    private func importFile(result: Result<URL, Error>) {
        main.backgroundTask(message: NSLocalizedString("Importing app...", comment: "AppsView")) {
            let url = try result.get()
            try main.importApp(url)
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

struct AppsView_Previews: PreviewProvider {
    static var previews: some View {
        AppsView()
    }
}
