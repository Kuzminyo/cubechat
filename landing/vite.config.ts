import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Narrow by hand rather than pulling in @types/node.
//
// This config is the only file in `landing/` that reads an environment
// variable, and the alternative is a dev dependency whose whole job is to
// describe a global we use once. Declared this narrowly, a typo in the name is
// still a type error.
declare const process: { env: Record<string, string | undefined> }

// The base path is where this site will be *served from*, and it differs by
// destination rather than by preference.
//
// On a custom domain the site is the whole origin, so the base is `/` and every
// asset resolves from the root. On github.io it is a folder inside the account
// domain — kuzminyo.github.io/cubechat/ — and a base of `/` there produces a
// page whose CSS, JS and favicon all 404 while the HTML itself loads fine. That
// is a blank white page with no error worth reading, which is why this is set
// by the workflow rather than left to be discovered.
//
// Set PAGES_BASE=/cubechat/ for github.io; leave it unset for a custom domain,
// which is the case `landing/` runs in locally too.
//
// https://vite.dev/config/
export default defineConfig({
  base: process.env.PAGES_BASE ?? '/',
  plugins: [react()],
})
