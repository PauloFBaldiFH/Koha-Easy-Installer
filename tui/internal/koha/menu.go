// Package koha knows the Koha panel (the installer's config.sh): its
// menu, how to reach it on this host, and its status.
package koha

// Item is one entry of the management panel. A group has Children; a leaf
// runs either a panel routine in the terminal (Run, the installer's
// "--run <action>") or a non-interactive panel command whose output goes
// to the log viewer (Args).
type Item struct {
	Icon     string
	Label    string
	Desc     string
	Run      string
	Args     []string
	Confirm  bool
	Children []Item
}

// Streamed reports whether the item's output goes to the log viewer.
func (it Item) Streamed() bool { return len(it.Args) > 0 }

// Menu mirrors the panel's main menu and KohaEasy.Window.ps1's $panelMenu.
// Icons are single-width symbols so columns line up in every terminal.
func Menu() []Item {
	return []Item{
		{Icon: "⚙", Label: "Install Koha server", Desc: "Installs Koha, MariaDB, Apache and the search engine on this server.", Run: "install"},
		{Icon: "ℹ", Label: "First-access credentials", Desc: "Shows the staff login created by the installation.", Run: "credentials"},
		{Icon: "↻", Label: "Restore database", Desc: "Replaces the catalogue with a backup. The current data is overwritten.", Run: "restore", Confirm: true},
		{Icon: "▣", Label: "Backup center", Desc: "Manual, cloud and verified backups.", Children: []Item{
			{Label: "Generate manual backup", Run: "backup-manual"},
			{Label: "Configure cloud backup (Google Drive)", Run: "backup-cloud"},
			{Label: "Test integrity of latest backup", Run: "backup-test"},
		}},
		{Icon: "⌕", Label: "Search & indexing", Desc: "Search engine choice and index maintenance.", Children: []Item{
			{Label: "Rebuild search index (log below)", Args: []string{"--rebuild-search-index"}},
			{Label: "Toggle search engine (Zebra ⇄ Elasticsearch)", Run: "search-toggle", Confirm: true},
			{Label: "Repair / rebuild indexing", Run: "search-repair"},
		}},
		{Icon: "☁", Label: "Publish to internet", Desc: "Make the catalogue reachable from outside the library.", Children: []Item{
			{Label: "Cloudflare Tunnel manager (recommended)", Run: "cloudflare"},
			{Label: "Free SSL certificate (Certbot / Apache)", Run: "ssl"},
			{Label: "Google Search Console assistant", Run: "search-console"},
		}},
		{Icon: "◈", Label: "Diagnostic & maintenance", Desc: "Health checks, logs and repairs.", Children: []Item{
			{Label: "Detailed server & Koha status", Run: "status"},
			{Label: "Full system health check", Run: "health"},
			{Label: "View latest validation report", Run: "validation-report"},
			{Label: "Real-time Apache log auditing", Run: "apache-log"},
			{Label: "Deep database optimization & log cleanup", Run: "db-maintenance", Confirm: true},
			{Label: "Restart / repair Koha services", Run: "repair-services"},
			{Label: "Export diagnostics to /tmp (log below)", Args: []string{"--export-diagnostics", "/tmp"}},
		}},
		{Icon: "⚠", Label: "Security center", Desc: "Firewall, intrusion attempts and secrets.", Children: []Item{
			{Label: "Fail2ban status (intrusion attempts)", Run: "fail2ban"},
			{Label: "Staff firewall (restrict port 8080)", Run: "staff-firewall"},
			{Label: "Rotate database password", Run: "rotate-db-password", Confirm: true},
			{Label: "Show active UFW rules", Run: "ufw"},
		}},
		{Icon: "≡", Label: "Koha configuration", Desc: "Server sizing, email, accounts and protocols.", Children: []Item{
			{Label: "Server sizing (memory / workers)", Run: "sizing"},
			{Label: "Configure email and circulation notices", Run: "email"},
			{Label: "Create super librarian", Run: "superlibrarian"},
			{Label: "Enable interoperability (SIP2 and Z39.50)", Run: "interoperability"},
			{Label: "Clock and timezone (NTP)", Run: "clock"},
		}},
		{Icon: "▦", Label: "Library tools", Desc: "Cataloguing helpers: Cutter, CDD, imports and more.", Run: "library-tools"},
		{Icon: "▤", Label: "General tools", Desc: "Terminal utilities, opened right here.", Children: []Item{
			{Label: "Resource monitoring (Htop / Nethogs)", Run: "monitor"},
			{Label: "Terminal web browser (Links)", Run: "links"},
			{Label: "File explorer (Midnight Commander)", Run: "mc"},
		}},
	}
}
