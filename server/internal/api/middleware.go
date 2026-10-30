package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/remotedesk/server/internal/auth"
)

type ctxKey string

const claimsKey ctxKey = "claims"

// auth 为 JWT 鉴权中间件，将解析出的 Claims 注入请求上下文。
func (a *API) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			writeErr(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		token := strings.TrimPrefix(h, "Bearer ")
		claims, err := auth.ParseToken(a.cfg.JWTSecret, token)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "invalid token")
			return
		}
		ctx := context.WithValue(r.Context(), claimsKey, claims)
		next(w, r.WithContext(ctx))
	}
}

func getClaims(r *http.Request) *auth.Claims {
	c, _ := r.Context().Value(claimsKey).(*auth.Claims)
	return c
}
