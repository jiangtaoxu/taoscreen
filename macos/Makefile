.PHONY: test build release publish upload

# 发布读取 RELEASE_NOTES.md 和部署者提供的配置。
test:
	swift test

build:
	./scripts/build-app.sh

release:
	./scripts/build-release.sh

publish:
	./scripts/publish-production.sh

upload:
	./scripts/upload-release.sh
