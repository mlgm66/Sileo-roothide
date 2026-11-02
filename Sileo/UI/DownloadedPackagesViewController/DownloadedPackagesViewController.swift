import UIKit
import Evander
import SwipeCellKit

final class DownloadedPackagesViewController: SileoTableViewController, SwipeTableViewCellDelegate {
    private var records: [DownloadedPackage] = []
    private var loadGeneration = 0
    private let emptyLabel = UILabel()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localizationKey: "Downloaded_Packages.Title")
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 73
        tableView.tableFooterView = UIView()
        tableView.register(DownloadedPackageCell.self, forCellReuseIdentifier: "DownloadedPackageCell")

        emptyLabel.text = String(localizationKey: "Downloaded_Packages.Empty")
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.adjustsFontForContentSizeCategory = true

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadData),
                                               name: DownloadedPackageManager.changedNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateSileoColors),
                                               name: SileoThemeManager.sileoChangedThemeNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadData),
                                               name: PackageListManager.reloadNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadData),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
        updateSileoColors()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        for case let cell as SwipeTableViewCell in tableView.visibleCells {
            cell.hideSwipe(animated: false)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateSileoColors()
    }

    @objc private func updateSileoColors() {
        guard isViewLoaded else { return }
        tableView.backgroundColor = .sileoBackgroundColor
        tableView.separatorColor = .sileoSeparatorColor
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        tableView.separatorInset = UIEdgeInsets(top: 0, left: rightToLeft ? 0 : 72,
                                               bottom: 0, right: rightToLeft ? 72 : 0)
        emptyLabel.textColor = .sileoLabel
        statusBarStyle = .default
        tableView.reloadData()
    }

    @objc private func reloadData() {
        loadGeneration += 1
        let generation = loadGeneration
        let manager = DownloadedPackageManager.shared
        records = manager.currentRecords()
        tableView.backgroundView = records.isEmpty ? emptyLabel : nil
        tableView.reloadData()
        manager.loadRecords { [weak self] records in
            guard let self = self, generation == self.loadGeneration else { return }
            self.records = records
            self.emptyLabel.text = String(localizationKey: "Downloaded_Packages.Empty")
            self.tableView.backgroundView = records.isEmpty ? self.emptyLabel : nil
            self.tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadedPackageCell", for: indexPath) as? DownloadedPackageCell else {
            return UITableViewCell()
        }
        let record = records[indexPath.row]
        cell.delegate = self
        let package = record.package
        let author = [package?.author?.name, package?.maintainer?.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let fileSize = ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file)
        let rawArchitecture = package?.architecture ?? ""
        let architecture = rawArchitecture.hasPrefix("iphoneos-")
            ? String(rawArchitecture.dropFirst("iphoneos-".count))
            : rawArchitecture
        let date = dateFormatter.string(from: record.downloadedAt)
        let detail = package.map {
            [$0.version, author].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        } ?? (record.metadataLoaded ? String(localizationKey: "Downloaded_Packages.Unreadable") : "")
        let fileInfo = [architecture, fileSize, date].filter { !$0.isEmpty }.joined(separator: " · ")
        cell.configure(record, detail: detail, fileInfo: fileInfo)
        return cell
    }

    @available(iOS 13.0, *)
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let record = records[indexPath.row]
        let fileURL = DownloadedPackageManager.shared.fileURL(for: record)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let copyPath = UIAction(title: String(localizationKey: "Copy_Path"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = fileURL.path
            }
            var actions = [copyPath]
            var filzaURL = URLComponents()
            filzaURL.scheme = "filza"
            filzaURL.host = "view"
            filzaURL.path = fileURL.path
            if let url = filzaURL.url, UIApplication.shared.canOpenURL(url) {
                actions.append(UIAction(title: String(localizationKey: "Open_In_Filza"), image: UIImage(systemName: "folder")) { _ in
                    UIApplication.shared.open(url)
                })
            }
            actions.append(UIAction(title: String(localizationKey: "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.delete(record)
            })
            return UIMenu(title: "", children: actions)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        share(records[indexPath.row], sourceRect: tableView.rectForRow(at: indexPath))
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> [SwipeAction]? {
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        guard orientation == (rightToLeft ? .left : .right),
              UserDefaults.standard.bool(forKey: "SwipeActions", fallback: true) else { return nil }
        let record = records[indexPath.row]
        let share = SwipeAction(style: .default, title: String(localizationKey: "Share")) { [weak self] _, indexPath in
            guard let self = self else { return }
            (self.tableView.cellForRow(at: indexPath) as? SwipeTableViewCell)?.hideSwipe(animated: true)
            self.share(record, sourceRect: self.tableView.rectForRow(at: indexPath))
        }
        share.image = UIImage(systemNameOrNil: "square.and.arrow.up")
        share.backgroundColor = .systemBlue

        let delete = SwipeAction(style: .default, title: String(localizationKey: "Delete")) { [weak self] _, indexPath in
            guard let self = self else { return }
            (self.tableView.cellForRow(at: indexPath) as? SwipeTableViewCell)?.hideSwipe(animated: false)
            self.delete(record)
        }
        delete.image = UIImage(systemNameOrNil: "trash")
        delete.backgroundColor = .systemRed
        return [delete, share]
    }

    @discardableResult private func delete(_ record: DownloadedPackage) -> Bool {
        do {
            try DownloadedPackageManager.shared.delete(record)
            return true
        } catch {
            presentError(error, titleKey: "Downloaded_Packages.Delete_Failed")
            return false
        }
    }

    private func share(_ record: DownloadedPackage, sourceRect: CGRect) {
        do {
            let url = try DownloadedPackageManager.shared.shareCopy(record)
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = tableView
            controller.popoverPresentationController?.sourceRect = sourceRect
            controller.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            present(controller, animated: true)
        } catch {
            presentError(error, titleKey: "Downloaded_Packages.Share_Failed")
        }
    }

    private func presentError(_ error: Error, titleKey: String) {
        let alert = UIAlertController(title: String(localizationKey: titleKey),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .default))
        present(alert, animated: true)
    }
}

private final class DownloadedPackageCell: SwipeTableViewCell {
    private let packageIcon = PackageIconView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let fileInfoLabel = UILabel()
    private var recordID: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectedBackgroundView = SileoSelectionView(frame: .zero)
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 14, weight: .medium)
        fileInfoLabel.font = .systemFont(ofSize: 12)
        for label in [nameLabel, detailLabel, fileInfoLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        let labels = UIStackView(arrangedSubviews: [nameLabel, detailLabel, fileInfoLabel])
        labels.axis = .vertical
        labels.spacing = 3
        labels.setCustomSpacing(2, after: nameLabel)
        let row = UIStackView(arrangedSubviews: [packageIcon, labels])
        row.alignment = .top
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            packageIcon.widthAnchor.constraint(equalToConstant: 40),
            packageIcon.heightAnchor.constraint(equalToConstant: 40),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9)
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateSileoColors() {
        nameLabel.textColor = .sileoLabel
        let secondaryColor = UIColor(red: 143 / 255, green: 142 / 255, blue: 148 / 255, alpha: 1)
        detailLabel.textColor = secondaryColor
        fileInfoLabel.textColor = secondaryColor
    }

    func configure(_ record: DownloadedPackage, detail: String, fileInfo: String) {
        updateSileoColors()
        recordID = record.id
        nameLabel.text = record.package?.name ?? record.fileURL.lastPathComponent
        detailLabel.text = detail
        fileInfoLabel.text = fileInfo
        accessibilityLabel = [nameLabel.text, detailLabel.text, fileInfoLabel.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        packageIcon.image = DownloadedPackageManager.shared.loadIcon(for: record) { [weak self] image in
            guard self?.recordID == record.id else { return }
            self?.packageIcon.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        recordID = nil
        packageIcon.image = nil
    }
}
