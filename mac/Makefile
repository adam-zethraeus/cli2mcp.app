APP := build/Cli2MCP.app
APPLICATIONS := /Applications

.PHONY: dev app sign-distribution run-app install reinstall test clean help

help:
	@echo "Targets:"
	@echo "  dev          build helper + run app"
	@echo "  app          build/Cli2MCP.app           (release build, ad-hoc signed)"
	@echo "  sign-distribution build + Developer ID sign for distribution"
	@echo "  run-app      build + open                (sanity-check launch)"
	@echo "  install      build + copy to /Applications/"
	@echo "  reinstall    install, replacing any existing /Applications/Cli2MCP.app"
	@echo "  test         build helper + swift test + native smoke"
	@echo "  clean        wipe build artifacts (build/ and .build/)"

dev:
	swift build --product cli2mcp-server
	swift run Cli2MCPApp

test:
	Scripts/test-native.sh

# Always re-run; swift build short-circuits internally if nothing changed,
# and re-running the bundle/sign step is cheap.
app:
	Scripts/build-app.sh

sign-distribution:
	SIGN_IDENTITY=- Scripts/build-app.sh
	SIGN_IDENTITY="$(SIGN_IDENTITY)" Scripts/sign-distribution.sh

run-app: app
	open "$(APP)"

install: app
	@if [ -e "$(APPLICATIONS)/Cli2MCP.app" ]; then \
	  echo "Cli2MCP.app already exists in $(APPLICATIONS)/. Use 'make reinstall' to overwrite."; \
	  exit 1; \
	fi
	cp -R "$(APP)" "$(APPLICATIONS)/"
	@echo "Installed: $(APPLICATIONS)/Cli2MCP.app"

reinstall: app
	rm -rf "$(APPLICATIONS)/Cli2MCP.app"
	cp -R "$(APP)" "$(APPLICATIONS)/"
	@echo "Reinstalled: $(APPLICATIONS)/Cli2MCP.app"

clean:
	rm -rf build .build
