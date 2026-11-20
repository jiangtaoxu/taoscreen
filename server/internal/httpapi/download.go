package httpapi

import (
	_ "embed"
	"net/http"
)

//go:embed download.html
var downloadHTML string
var downloadTemplate = webTemplate("download", downloadHTML)

func (s *Server) downloadPage(w http.ResponseWriter, r *http.Request) error {
	nonce, err := randomToken()
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'nonce-"+nonce+"'; style-src 'nonce-"+nonce+"'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	return downloadTemplate.Execute(w, webPageData{Language: s.webLanguage(w, r), Nonce: nonce})
}
