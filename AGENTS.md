# Repository Guidelines

## Project Structure & Module Organization
`sub2api` is a monorepo with a Go backend and Vue frontend.
- `backend/cmd/server`: backend entrypoint and build metadata.
- `backend/internal`: core application layers (`handler`, `service`, `repository`, `server`, `config`, etc.).
- `backend/ent` and `backend/migrations`: generated ORM code and SQL migrations.
- `frontend/src`: Vue app (`views`, `components`, `stores`, `api`, `composables`, `utils`).
- `deploy`: Docker Compose, systemd units, and deployment scripts.
- `docs` and `tools`: project docs and maintenance/security scripts.

## Build, Test, and Development Commands
- `make build`: build backend and frontend from repo root.
- `make test`: run backend tests plus frontend lint/type checks.
- `cd backend && make build`: build backend binary to `backend/bin/server`.
- `cd backend && make test`: run `go test ./...` and `golangci-lint`.
- `cd backend && go test -tags=unit ./...` / `-tags=integration`: run CI-equivalent suites.
- `cd backend && go generate ./ent && go generate ./cmd/server`: regenerate Ent/Wire after schema or DI changes.
- `cd frontend && pnpm install && pnpm run dev`: install deps and start Vite dev server.
- `cd frontend && pnpm run build && pnpm run test:run`: production build and Vitest run.

## Coding Style & Naming Conventions
- Go version is pinned to `1.25.8`; format with `gofmt` and keep lint clean under `backend/.golangci.yml`.
- Respect architecture boundaries: `internal/service` and `internal/handler` must not import `internal/repository` directly (enforced by `depguard`).
- Vue/TS uses strict TypeScript and ESLint (`frontend/.eslintrc.cjs`); keep components in `PascalCase` (`UserEditModal.vue`) and composables as `useXxx.ts`.
- Use `pnpm` for frontend dependency changes and commit `frontend/pnpm-lock.yaml`.

## Testing Guidelines
- Backend tests use `*_test.go`; prefer table-driven tests for service/repository logic.
- Run both unit and integration suites before PRs.
- Frontend tests use Vitest + jsdom with files like `*.spec.ts`/`*.test.ts` under `frontend/src`.
- Frontend coverage threshold is `80%` globally (`pnpm run test:coverage`).

## Commit & Pull Request Guidelines
- Follow Conventional Commit style seen in history: `feat(...)`, `fix(...)`, `refactor`, `test`, `chore`, `revert`.
- Keep subject lines imperative and scoped when useful, e.g. `feat(openai-handler): support compact outcome logging`.
- PRs should include: purpose, impacted modules, migration/config changes, and UI screenshots for frontend-visible changes.
- Before opening a PR, ensure backend CI checks pass locally and there are no new lint/security issues.

## Security & Configuration Tips
- Start from `deploy/config.example.yaml`; never commit real secrets or `.env` credentials.
- Keep dependency-risk exceptions in `.github/audit-exceptions.yml` minimal, justified, and time-bounded.
