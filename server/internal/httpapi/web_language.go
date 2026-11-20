package httpapi

import (
	_ "embed"
	"encoding/json"
	"html/template"
	"net/http"

	"golang.org/x/text/language"
)

const webLanguageCookie = "taoscreen_lang"

//go:embed web_language.html
var webLanguageMenu string

//go:embed web_english.json
var webEnglishJSON []byte

var webEnglish = loadWebEnglish()

func loadWebEnglish() map[string]string {
	var translations map[string]string
	if err := json.Unmarshal(webEnglishJSON, &translations); err != nil {
		panic(err)
	}
	return translations
}

func webText(locale, text string) string {
	if locale == "en" {
		if translated, ok := webEnglish[text]; ok {
			return translated
		}
	}
	return text
}

func webTemplate(name, source string) *template.Template {
	return template.Must(template.New(name).Funcs(template.FuncMap{"tr": webText}).Parse(source + webLanguageMenu))
}

type webPageData struct {
	Language    string
	Nonce       string
	Message     string
	RequireTOTP bool
}

func (s *Server) webLanguage(w http.ResponseWriter, r *http.Request) (locale string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Add("Vary", "Accept-Language, Cookie")
	defer func() { w.Header().Set("Content-Language", locale) }()
	choice := r.URL.Query().Get("lang")
	if r.Method == http.MethodGet && (choice == "en" || choice == "zh-Hans" || choice == "system") {
		secure, _ := s.credentialTransport(r)
		cookie := &http.Cookie{Name: webLanguageCookie, Path: "/", HttpOnly: true, Secure: secure, SameSite: http.SameSiteLaxMode}
		if choice == "system" {
			cookie.MaxAge = -1
		} else {
			cookie.Value = choice
			cookie.MaxAge = 365 * 24 * 60 * 60
		}
		http.SetCookie(w, cookie)
		if choice != "system" {
			return choice
		}
		return preferredWebLanguage(r.Header.Get("Accept-Language"))
	}
	return requestLanguage(r)
}

func requestLanguage(r *http.Request) string {
	if cookie, err := r.Cookie(webLanguageCookie); err == nil {
		if cookie.Value == "en" || cookie.Value == "zh-Hans" {
			return cookie.Value
		}
	}
	return preferredWebLanguage(r.Header.Get("Accept-Language"))
}

func preferredWebLanguage(header string) string {
	if header == "" {
		return "zh-Hans"
	}
	tags, _, err := language.ParseAcceptLanguage(header)
	if err == nil {
		for _, tag := range tags {
			base, _ := tag.Base()
			switch base.String() {
			case "zh":
				return "zh-Hans"
			case "en":
				return "en"
			}
		}
	}
	return "en"
}
