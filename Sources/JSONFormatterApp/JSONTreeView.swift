import SwiftUI

struct JSONTreeView: View {
    let root: JSONTreeNode?
    @Binding var expandedNodeIDs: Set<String>
    let searchMatches: [JSONTreeSearchMatch]
    let currentMatchIndex: Int

    private var currentMatchID: String? {
        guard !searchMatches.isEmpty else {
            return nil
        }

        let safeIndex = min(max(currentMatchIndex, 0), searchMatches.count - 1)
        return searchMatches[safeIndex].nodeID
    }

    private var matchedNodeIDs: Set<String> {
        Set(searchMatches.map(\.nodeID))
    }

    var body: some View {
        Group {
            if let root {
                treeContent(root)
            } else {
                ContentUnavailableView(
                    "暂无可展示的 JSON 树",
                    systemImage: "list.bullet.indent",
                    description: Text("请先格式化或查询 JSON 输出。")
                )
            }
        }
    }

    private func treeContent(_ root: JSONTreeNode) -> some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = 10
            let availableRowWidth = max(geometry.size.width - horizontalPadding * 2, 0)

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows(for: root)) { row in
                            JSONTreeNodeRow(
                                node: row.node,
                                depth: row.depth,
                                minimumRowWidth: availableRowWidth,
                                isExpanded: expandedNodeIDs.contains(row.node.id),
                                isMatched: matchedNodeIDs.contains(row.node.id),
                                isCurrentMatch: currentMatchID == row.node.id,
                                toggleExpansion: {
                                    toggleExpansion(for: row.node)
                                }
                            )
                            .id(row.node.id)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(minWidth: availableRowWidth, maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, horizontalPadding)
                    .animation(.easeInOut(duration: 0.18), value: expandedNodeIDs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: currentMatchID) { _, nodeID in
                    guard let nodeID else {
                        return
                    }

                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(nodeID, anchor: .center)
                    }
                }
            }
        }
    }

    private func visibleRows(for root: JSONTreeNode) -> [JSONTreeVisibleRow] {
        var rows: [JSONTreeVisibleRow] = []
        appendVisibleRows(root, depth: 0, into: &rows)
        return rows
    }

    private func appendVisibleRows(_ node: JSONTreeNode, depth: Int, into rows: inout [JSONTreeVisibleRow]) {
        rows.append(JSONTreeVisibleRow(node: node, depth: depth))
        guard expandedNodeIDs.contains(node.id) else {
            return
        }

        for child in node.children {
            appendVisibleRows(child, depth: depth + 1, into: &rows)
        }
    }

    private func toggleExpansion(for node: JSONTreeNode) {
        guard node.isExpandable else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedNodeIDs.contains(node.id) {
                expandedNodeIDs.remove(node.id)
            } else {
                expandedNodeIDs.insert(node.id)
            }
        }
    }
}

private struct JSONTreeVisibleRow: Identifiable {
    let node: JSONTreeNode
    let depth: Int

    var id: String {
        node.id
    }
}

private struct JSONTreeNodeRow: View {
    let node: JSONTreeNode
    let depth: Int
    let minimumRowWidth: CGFloat
    let isExpanded: Bool
    let isMatched: Bool
    let isCurrentMatch: Bool
    let toggleExpansion: () -> Void

    private var rowBackground: Color {
        if isCurrentMatch {
            return Color.orange.opacity(0.28)
        }

        if isMatched {
            return Color.yellow.opacity(0.18)
        }

        return Color.clear
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Color.clear
                    .frame(width: CGFloat(depth) * 18, height: 1)
                    .fixedSize(horizontal: true, vertical: false)

                Button(action: toggleExpansion) {
                    Image(systemName: node.isExpandable ? (isExpanded ? "chevron.down" : "chevron.right") : "circle.fill")
                        .font(.system(size: node.isExpandable ? 10 : 4, weight: .semibold, design: .monospaced))
                        .foregroundStyle(node.isExpandable ? .secondary : .tertiary)
                        .frame(width: 14, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(!node.isExpandable)
                .fixedSize(horizontal: true, vertical: false)

                Text(node.label)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .textSelection(.enabled)

                Text(node.summary)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(node.isExpandable ? .secondary : .primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(minWidth: max(minimumRowWidth, 0), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggleExpansion)
    }
}
