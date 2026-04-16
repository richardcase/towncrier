# Feature Landscape: Towncrier

**Domain:** Cross-platform system tray notification aggregator (GitHub + GitLab)
**Researched:** 2026-04-16
**Overall confidence:** HIGH (API docs verified), MEDIUM (competitor analysis)

---

## API Coverage Map

Understanding what each API actually delivers is prerequisite to defining features.
Gaps here directly constrain what Towncrier can promise users.

### GitHub Notifications API

**Endpoint:** `GET /notifications` (REST)
**What it covers:**

| Reason code | Meaning | Subject types available |
|-------------|---------|------------------------|
| `review_requested` | You were asked to review a PR | PullRequest |
| `assign` | You were assigned to an issue/PR | Issue, PullRequest |
| `mention` | You were @mentioned | Issue, PullRequest, Commit, Discussion |
| `team_mention` | Your team was @mentioned | Issue, PullRequest |
| `comment` | Someone commented on a thread you participate in | Issue, PullRequest, Commit |
| `author` | Activity on something you created | Issue, PullRequest, Commit |
| `ci_activity` | A GitHub Actions workflow run you triggered completed | CheckSuite, WorkflowRun |
| `state_change` | An issue/PR you're subscribed to was opened/closed/merged | Issue, PullRequest |
| `approval_requested` | PR approval requested | PullRequest |
| `security_alert` | Dependabot/advisory alert | RepositoryVulnerabilityAlert |
| `subscribed` | You're watching the repo | Issue, PullRequest, Release, Discussion |
| `invitation` | Invited to a repo | — |
| `manual` | You manually subscribed to this thread | any |
| `member_feature_requested` | — | — |
| `security_advisory_credit` | — | — |

**Polling mechanics (HIGH confidence — official docs):**
- `Last-Modified` / `If-Modified-Since` conditional requests: 304 responses do NOT count against rate limit
- `X-Poll-Interval` header specifies minimum seconds between polls; may increase under server load — must be respected
- Rate limit: 5,000 requests/hour for authenticated users; 304s are free
- Minimum recommended poll interval: whatever `X-Poll-Interval` says (typically 60s)
- Marking read: `PATCH /notifications/threads/:thread_id` or bulk `PUT /notifications`

**CI coverage note:** The `ci_activity` reason fires when a workflow run you *triggered* completes. Notifications for pipelines on PRs you *reviewed* but didn't trigger are not guaranteed to appear here — they surface only if you're subscribed or authored the PR.

---

### GitLab Todo API

**Endpoint:** `GET /todos` (REST)
**What it covers:**

| Action | Meaning | Target types |
|--------|---------|-------------|
| `assigned` | Issue/MR assigned to you | Issue, MergeRequest |
| `mentioned` | You were @mentioned | Issue, MergeRequest, Commit, Epic |
| `directly_addressed` | First in a @mention list | Issue, MergeRequest, Commit |
| `build_failed` | A CI pipeline failed on an MR you authored | MergeRequest |
| `approval_required` | Your approval is required | MergeRequest |
| `unmergeable` | MR you authored can no longer auto-merge | MergeRequest |
| `merge_train_removed` | Your MR was removed from the merge train | MergeRequest |
| `member_access_requested` | A user requested access to your group/project | Project, Namespace |
| `marked` | You manually created a todo | any |

**State management:** Items are either `pending` or `done`. `POST /todos/:id/mark_as_done` for individual; `POST /todos/mark_as_done` for all.

**API scope required:** `api` or `read_api` PAT scope; for OAuth: `read_user` + `api` scope.

**Rate limits — GitLab.com:** 2,000 requests/minute for authenticated users (HIGH confidence — official docs). Self-hosted default: 7,200 requests/hour (120/min), configurable by admin.

**Critical gaps in GitLab Todo API (MEDIUM confidence):**

1. **No pipeline status for non-authored pipelines.** `build_failed` only fires for MRs you authored. If you're a reviewer and want to know pipeline status on a PR you reviewed — not available via todos. You must separately poll `GET /projects/:id/pipelines?updated_after=<timestamp>`.

2. **No generic "pipeline succeeded/failed" notification.** To show "your branch's pipeline passed", you need to enumerate projects and poll pipelines independently. The Todo API will not surface this.

3. **No "pipeline running" or "pipeline queued" state.** Todos only capture terminal failure state (`build_failed`). In-progress status requires polling `GET /projects/:id/pipelines` with `status=running`.

4. **No equivalent of GitHub's `subscribed` reason.** GitLab todos are strictly action-triggered. You cannot get notified for arbitrary repo activity just by watching a project.

5. **Pagination required.** GitLab Todo API returns paginated results (default 20, max 100 per page). High-volume users may have many pending todos that require multiple requests per poll cycle.

6. **Self-hosted instance discovery.** Each self-hosted instance is a separate API root. The app must store base URLs per account and make all API calls scoped to that URL.

---

### GitLab Pipeline Polling (Supplementary)

To cover CI status for all relevant projects, the app must maintain a project list per GitLab account and poll separately:

```
GET /projects/:id/pipelines?updated_after=<last_poll_timestamp>&scope=finished
```

Supported filter values for `scope`: `running`, `pending`, `finished`, `branches`, `tags`
Supported `updated_after`: ISO 8601 timestamp — ideal for efficient delta polling.

**Implementation cost:** Medium-high. Requires: (a) user selects or app discovers which projects to watch, (b) per-project polling loop, (c) deduplication against todos already surfaced by the Todo API. This is additive complexity on top of the Todo API.

---

## Table Stakes

Features users will expect. Absence makes the product feel incomplete or broken.

| Feature | Why Expected | Complexity | API Coverage | Notes |
|---------|--------------|------------|--------------|-------|
| GitHub PR review requests | Primary use case for most devs | Low | Full — `review_requested` reason | Direct from notifications API |
| GitHub issue/PR assignments | Daily workflow | Low | Full — `assign` reason | Direct |
| GitHub @mentions | Communication signal | Low | Full — `mention`, `team_mention` | Direct |
| GitHub CI status (user-triggered) | Know when your Actions run finishes | Low | Partial — `ci_activity` fires only for runs you triggered | Documents well in the reason field |
| GitLab MR assignments | Daily workflow | Low | Full — `assigned` via Todo API | |
| GitLab @mentions | Communication signal | Low | Full — `mentioned`, `directly_addressed` | |
| GitLab MR approval requests | Reviewer workflow | Low | Full — `approval_required` | |
| GitLab build failures on authored MRs | CI feedback loop | Low | Full — `build_failed` via Todo API | |
| Grouped by repository | Visual organisation — gitify does this, users now expect it | Medium | N/A — requires client-side grouping | Grouping logic lives in core lib |
| Unread count in tray icon | "Is there anything new?" at a glance | Low | N/A — derived from local state | Count tracked locally |
| Click to open in browser | The primary action on a notification | Low | N/A — URL is in the API response | Both APIs return `web_url` or `html_url` |
| Mark as read on click | Keeps inbox clean | Low | GitHub: thread PATCH. GitLab: todo mark_as_done | Both well-supported |
| PAT authentication | Required for enterprise/self-hosted where OAuth is restricted | Low | Both APIs accept Bearer token | Also simplest for developers |
| OAuth authentication | Better UX than copy-pasting tokens | Medium | GitHub: device flow. GitLab: device flow (17.2+) | See OAuth section below |
| Multiple accounts per service | Devs commonly have personal + work accounts | Medium | N/A — requires per-account polling loops | Core polling engine must be account-scoped |
| System keychain token storage | Security expectation — tokens must not be in plaintext | Medium | N/A — platform integration | macOS: Keychain Services. Linux: libsecret/Secret Service |
| Configurable poll interval | Power users want control; battery-sensitive users want longer intervals | Low | Must respect GitHub's `X-Poll-Interval` floor | |
| Persistent read/unread state across restarts | Feels broken if everything resets | Medium | Local state store needed | SQLite or flat file in app data dir |

---

## Differentiators

Features that set Towncrier apart from existing tools like Gitify (GitHub-only) and Gitlight (both, but Electron).

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Unified GitHub + GitLab in one inbox | No existing native tray app does this well. Gitify is GitHub-only. Gitlight is Electron-based, not native. | High | The whole product thesis |
| Native tray app (not Electron) | Lower memory, faster startup, system-appropriate UI. Gitify and Gitlight are Electron. | High | Architecture decision already made — Swift + Zig/GTK |
| GitLab CI pipeline status (beyond Todo API) | Todo API only fires on your own MR failures. Surfacing broader pipeline status requires extra polling. | High | Requires project enumeration + pipeline polling loop. High complexity but high value. |
| Self-hosted GitLab first-class support | Many enterprise devs run private instances. Most tools treat self-hosted as an afterthought. | Medium | Per-account base URL config already planned |
| Multiple accounts per service | Gitify added this relatively recently; many tools still lack it | Medium | Already in requirements — mention it in UX as a selling point |
| Tray icon per-service unread counts | Show separate GitHub / GitLab counts, not just a combined total | Low | Visual differentiation; requires small design work |
| Notification type filtering | Show only "review requested" and "assigned" — ignore noise. Gitify added this; users love it | Medium | Filter state persisted locally per account |
| Repo-level muting | Some repos are noisy; mute them without leaving GitHub/GitLab | Medium | Requires local allowlist/denylist per account |
| Keyboard-driven tray popover | Power users navigate notifications without mouse | Medium | Platform-specific (NSMenu on macOS, GTK on Linux) |

---

## Anti-Features

Deliberate omissions that keep the product focused and avoid complexity traps.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Desktop OS notification popups (system banners) | Invasive, per-OS permission management, user backlash for noisy apps. Already out of scope for v1. | Tray icon badge + unread count is sufficient signal |
| Webhook ingestion server | Eliminates the "no server-side component" advantage; complicates distribution and self-hosting | Polling with `If-Modified-Since` / `updated_after` is efficient enough |
| Full notification filtering DSL (regex, custom rules) | High implementation complexity; risk of building a feature only power users use. | Basic type filter + repo mute covers 90% of use cases |
| GitLab CI log streaming or artifact downloads | Out of notification scope; turns this into a CI dashboard | Deep-link to the pipeline URL in the browser |
| In-app thread replies | Turns the app into a GitHub/GitLab client; explodes scope | Open in browser for any interaction beyond mark-read |
| Windows support | Already out of scope; adds third shell, third keychain integration | macOS + Linux covers the target audience |
| Repository browsing or search | This is not a Git client | Notifications only |
| Email/Slack notification forwarding | Scope creep; users already have those channels | Tray is the only output channel |
| Auto-refresh token rotation in background daemon | Daemon adds complexity; OAuth token refresh on launch + expiry check is sufficient | Prompt re-auth when token is invalid |

---

## OAuth Flow Details

**GitHub (HIGH confidence — official docs):**
- Device Authorization Flow is the correct choice for desktop apps that can't guarantee a loopback server
- Web flow with loopback redirect (`http://127.0.0.1:<port>`) is an alternative but requires a local HTTP server
- GitHub Enterprise Server supports OAuth but device flow requires manual hostname config; PAT is simpler fallback
- PKCE support was added for OAuth/GitHub App auth (GitHub changelog, July 2025) — but device flow doesn't use PKCE
- Required PAT scopes: `notifications`, `read:user`, `repo` (or `public_repo` for public-only)

**GitLab (HIGH confidence — official docs):**
- Device Authorization Grant flow introduced in GitLab 17.2, enabled by default in 17.3, GA in 17.9
- Before 17.2 (older self-hosted instances): web flow with loopback redirect or PAT only
- Must handle both: device flow for modern instances, PAT fallback for old self-hosted
- Required scopes: `read_api` (read-only access to todos, pipelines, MR data)
- The GitLab CLI (`glab`) migrated from web redirect to device flow as of their MR !2025 — confirms this is the ecosystem standard

**Multi-account auth implication:** Each account (per service) carries its own token, refresh state, and base URL. Auth state is completely independent across accounts. The core lib must model accounts as first-class entities, not as a singleton per service.

---

## Feature Dependencies

```
OAuth flow (GitHub device)
    └── requires: OAuth app registration (client_id/client_secret) bundled with app

OAuth flow (GitLab device)
    └── requires: GitLab OAuth application registration
    └── requires: knowing base URL before auth starts (self-hosted config step comes first)

GitLab pipeline CI status (beyond Todo API)
    └── requires: project list per account (user must select OR app must discover)
    └── requires: separate polling loop from Todo loop
    └── adds: deduplication with build_failed todos

Multi-account polling
    └── requires: per-account state: token, base URL, last-seen timestamps, unread list
    └── requires: polling scheduler that handles N accounts with independent intervals

Mark as read
    └── GitHub: requires `notifications` write scope (included in `notifications` PAT scope)
    └── GitLab: requires `api` scope (not just `read_api`) — marking todos done is a write operation

Persistent state across restarts
    └── requires: local state store (SQLite recommended — structured, concurrent-safe, zero-server)
    └── requires: migration strategy for schema changes

Notification grouping by repository
    └── requires: repository identifier on every notification object (both APIs provide this)
    └── client-side grouping only — no API support needed
```

---

## MVP Recommendation

Prioritize for first shippable version:

1. GitHub notifications (review requests, assignments, mentions, CI activity) via Notifications API
2. GitLab todos (MR assignments, mentions, approval requests, build failures) via Todo API
3. Group by repository (client-side)
4. PAT authentication for both services (simpler than OAuth for v1)
5. Tray icon with unread count badge
6. Click to open in browser + mark as read
7. Multiple accounts per service
8. System keychain token storage

Defer to v2:
- OAuth device flow (PAT covers all auth needs for v1; OAuth improves onboarding UX)
- GitLab pipeline polling beyond Todo API (high complexity, covers an edge case most users won't notice immediately)
- Notification type filtering / repo muting (useful but not blocking launch)
- Tray icon per-service split counts

---

## Sources

- [GitHub Notifications API — official docs](https://docs.github.com/en/rest/activity/notifications) — HIGH confidence
- [GitHub Best Practices for REST API](https://docs.github.com/rest/guides/best-practices-for-using-the-rest-api) — HIGH confidence
- [GitHub Authorizing OAuth Apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps) — HIGH confidence
- [GitLab Todo API — official docs](https://docs.gitlab.com/api/todos.html) — HIGH confidence
- [GitLab Pipelines API — official docs](https://docs.gitlab.com/api/pipelines/) — HIGH confidence
- [GitLab OAuth2 Identity Provider API](https://docs.gitlab.com/api/oauth2/) — HIGH confidence
- [GitLab.com Rate Limits](https://docs.gitlab.com/user/gitlab_com/#rate-limits-on-gitlabcom) — HIGH confidence
- [GitLab User and IP Rate Limits (self-hosted)](https://docs.gitlab.com/administration/settings/user_and_ip_rate_limits/) — HIGH confidence
- [Gitify — features and FAQ](https://gitify.io/faq/) — MEDIUM confidence (competitor feature reference)
- [Gitlight — GitHub/GitLab desktop app](https://github.com/colinlienard/gitlight) — MEDIUM confidence (competitor reference)
- [CatLight GitLab Pipeline Notifications](https://catlight.io/a/gitlab-build-status-notifications) — MEDIUM confidence (competitor reference)
- [GitLab CLI device flow migration MR](https://gitlab.com/gitlab-org/cli/-/merge_requests/2025) — MEDIUM confidence
- [Gitify GitLab support issue (closed, no plans)](https://github.com/gitify-app/gitify/issues/237) — MEDIUM confidence (market gap confirmation)
