<!--
  version: 0.23.8
  Third-party license notices for software included in or distributed with evi.
  Lists direct runtime, toolchain, infrastructure, and host dependencies with SPDX license groups.
  File: THIRD-PARTY-NOTICES.md

  Changes in v0.23.8:
  - Components/notices lists now match lockfile and go.mod (jwt-decode + golang-jwt;
    npm jsonwebtoken and core-js are not product dependencies).
  - Frontend/backend/worker versions aligned with lockfile and go.mod; Vite, Node.js 24,
    TipTap, Mermaid, Vue Flow, dagre, gommon, x/net, go-mail, mimetype, SeaweedFS,
    aws-sdk-go-v2, Alpine 3.21, and host uidmap/ufw/jq listed.
  - dayjs listed as a notable ExcelJS transitive; jszip kept as a notable transitive.
  - LGPL-2.1: cockpit-files (Cockpit File browser, host-only).
-->

# Third-Party Notices

This file contains licenses and notices for third-party software included
in or distributed with EVI. Each dependency is listed under the license
that governs its use.

---

## MIT License

The following components are licensed under the MIT License.

Full text of the MIT License:

    Permission is hereby granted, free of charge, to any person obtaining
    a copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
    CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
    SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### Frontend (npm) — direct dependencies

- **Vue v3.5.40** — Copyright (c) 2013-present Yuxi (Evan) You — https://vuejs.org
- **Vuetify v3.12.11** — Copyright (c) 2016-present John Leider — https://vuetifyjs.com
- **Pinia v3.0.4** — Copyright (c) 2019-present Eduardo San Martin Morote — https://pinia.vuejs.org
- **pinia-plugin-persistedstate v4.7.1** — Copyright (c) 2021-present Sacha Bouillez — https://github.com/prazdevs/pinia-plugin-persistedstate
- **Vue I18n v11.4.7** — Copyright (c) 2016-present kazuya kawaguchi — https://vue-i18n.intlify.dev
- **Axios v1.18.1** — Copyright (c) 2014-present Matt Zabriskie & contributors — https://github.com/axios/axios
- **Phosphor Icons (Vue) v2.2.1** — Copyright (c) 2023 Phosphor Icons — https://phosphoricons.com
- **VueUse v14.3.0** — Copyright (c) 2019-present Anthony Fu — https://vueuse.org
- **jwt-decode v4.0.0** — Copyright (c) 2015 Auth0, Inc. — https://github.com/auth0/jwt-decode
- **ExcelJS v4.4.0** — Copyright (c) 2014-present Guyon Roche — https://github.com/exceljs/exceljs
- **lodash v4.18.1** — Copyright JS Foundation and other contributors — https://lodash.com
- **TipTap v3.29.0** — Copyright (c) 2025 Tiptap GmbH — https://tiptap.dev
- **Mermaid v11.16.0** — Copyright (c) 2014-present Knut Sveidqvist — https://mermaid.js.org
- **Vue Flow v1.48.2** — Copyright (c) Burak Cakmakoglu — https://vueflow.dev
- **dagre v3.1.0** — Copyright (c) Chris Pettitt — https://github.com/dagrejs/dagre
- **Vite v6.4.3** — Copyright (c) 2019-present VoidZero Inc. and Vite contributors — https://vite.dev
- **Node.js v24** — Copyright (c) Node.js contributors — https://nodejs.org

### Frontend (npm) — notable transitive dependencies

- **nanoid** — Copyright (c) 2017 Andrey Sitnik — MIT
- **postcss** — Copyright (c) 2013 Andrey Sitnik — MIT
- **magic-string** — Copyright (c) 2015 Rich Harris — MIT
- **follow-redirects** — Copyright (c) 2014 Olivier Lalonde and James Talmage — MIT
- **jszip** — Copyright (c) 2009-2016 Stuart Knightley et al. — MIT OR GPL-3.0-or-later
- **pako** — Copyright (c) 2014-2017 Vitaly Puzrin and Andrei Tuputcyn — MIT AND Zlib
- **dayjs** — Copyright (c) 2018-present iamkun — ExcelJS transitive — https://day.js.org

### Backend (Go) — direct dependencies

- **Echo v4.15.4** — Copyright (c) 2021 LabStack — https://echo.labstack.com
- **pgx/v5 v5.10.0** — Copyright (c) 2013-2021 Jack Christensen — https://github.com/jackc/pgx
- **golang-jwt/jwt v5.3.1** — Copyright (c) 2012 Dave Grijalva; 2021 golang-jwt maintainers — https://github.com/golang-jwt/jwt
- **go-playground/validator v10.30.3** — Copyright (c) 2015 Dean Karn — https://github.com/go-playground/validator
- **zerolog v1.35.1** — Copyright (c) 2017 Olivier Poitrey — https://github.com/rs/zerolog
- **godotenv v1.5.1** — Copyright (c) 2013 John Barton — https://github.com/joho/godotenv
- **gabriel-vasile/mimetype v1.4.15** — Copyright (c) 2018 Gabriel Vasile — https://github.com/gabriel-vasile/mimetype
- **labstack/gommon v0.5.0** — Copyright (c) 2015 LabStack — https://github.com/labstack/gommon

### Worker (Go) — direct dependencies

Same Go modules as listed above (pgx, zerolog, godotenv) are also used by the worker container,
plus **go-mail v0.8.1** — Copyright (c) 2022-present Winni Neessen — https://github.com/wneessen/go-mail
and **google/uuid v1.6.0** (BSD-3-Clause, listed below).

### Host (apt)

- **jq** — Copyright (c) 2012 Stephen Dolan — https://jqlang.org

---

## BSD-2-Clause License

Full text of the BSD 2-Clause License:

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
    A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
    HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
    LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

- **go-redis/v9 v9.21.0** — Copyright (c) 2013 The go-redis/redis Authors — https://github.com/redis/go-redis
- **Nginx** — Copyright (c) 2002-2024 Igor Sysoev, Nginx, Inc. — https://nginx.org
- **entities** — Copyright (c) Felix Böhm — https://github.com/fb55/entities

---

## BSD-3-Clause License

Full text of the BSD 3-Clause License:

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    3. Neither the name of the copyright holder nor the names of its
       contributors may be used to endorse or promote products derived
       from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
    A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
    HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
    LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

- **google/uuid v1.6.0** — Copyright (c) 2009, 2014 Google Inc. — https://github.com/google/uuid
- **golang.org/x/crypto v0.54.0** — Copyright (c) 2009 The Go Authors — https://pkg.go.dev/golang.org/x/crypto
- **golang.org/x/net v0.57.0** — Copyright (c) 2009 The Go Authors — https://pkg.go.dev/golang.org/x/net
- **Go v1.25 (programming language)** — Copyright (c) 2009 The Go Authors — https://go.dev
- **Valkey v8** — Copyright (c) 2006-2024 Salvatore Sanfilippo; 2024 Contributors to the Valkey project — https://valkey.io
- **@hapi/hoek v11.0.7** — Copyright (c) 2011-2022, Project contributors; Sideway Inc.; Walmart; Yahoo Inc. — https://github.com/hapijs/hoek
- **source-map-js** — Copyright (c) 2009-2011 Mozilla Foundation and contributors — https://github.com/nicolo-ribaudo/source-map-js
- **ieee754** — Copyright (c) 2008 Fair Oaks Labs, Inc. — https://github.com/feross/ieee754
- **speakingurl** — Copyright (c) 2013-2017 Sascha Droste — https://github.com/pid/speakingurl

---

## Apache License 2.0

The following components are licensed under the Apache License, Version 2.0.
You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

Full text: https://www.apache.org/licenses/LICENSE-2.0.txt

- **TypeScript v5.9.3** — Copyright (c) Microsoft Corporation — https://www.typescriptlang.org
- **roboto-fontface v0.10.0** (Roboto font) — Copyright (c) 2011 Google Inc. — https://github.com/choffmeister/roboto-fontface
- **Caddy v2.8** — Copyright (c) 2015-2024 Light Code Labs, LLC — https://caddyserver.com
- **Podman** — Copyright (c) 2018-2024 Red Hat, Inc. and contributors — https://podman.io
- **OpenSSL** — Copyright (c) 1998-2024 The OpenSSL Project Authors — https://www.openssl.org
- **apache2-utils** — Copyright (c) The Apache Software Foundation — https://httpd.apache.org
- **santhosh-tekuri/jsonschema v6.0.2** — Copyright (c) 2017 Santhosh Kumar Tekuri — https://github.com/santhosh-tekuri/jsonschema
- **aws-sdk-go-v2 v1.43.0** — Copyright (c) Amazon.com, Inc. or its affiliates — https://github.com/aws/aws-sdk-go-v2
- **SeaweedFS v4.17** — Copyright (c) Chris Lu and contributors — https://github.com/seaweedfs/seaweedfs
- **crc-32** — Copyright (c) 2014-present SheetJS LLC — https://github.com/SheetJS/js-crc32
- **readdir-glob** — Copyright (c) 2020 Yann Armelin — https://github.com/Yqnn/node-readdir-glob

---

## ISC License

The following components are licensed under the ISC License.

Full text of the ISC License:

    Permission to use, copy, modify, and/or distribute this software for
    any purpose with or without fee is hereby granted, provided that the
    above copyright notice and this permission notice appear in all copies.

    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
    WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
    AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
    DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
    PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
    TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
    PERFORMANCE OF THIS SOFTWARE.

- **semver** — Copyright (c) Isaac Z. Schlueter and Contributors — https://github.com/npm/node-semver
- **graceful-fs** — Copyright (c) Isaac Z. Schlueter, Ben Noordhuis, and Contributors — https://github.com/isaacs/node-graceful-fs
- **glob** — Copyright (c) Isaac Z. Schlueter and Contributors — https://github.com/isaacs/node-glob
- **minimatch** — Copyright (c) Isaac Z. Schlueter and Contributors — https://github.com/isaacs/minimatch
- **rimraf** — Copyright (c) Isaac Z. Schlueter and Contributors — https://github.com/isaacs/rimraf
- **saxes** — Copyright (c) Louis-Dominique Dubeau — https://github.com/lddubeau/saxes
- **picocolors** — Copyright (c) Alexey Raspopov — https://github.com/alexeyraspopov/picocolors

---

## PostgreSQL License

The PostgreSQL License is a liberal open source license, similar to the BSD
or MIT licenses. Full text: https://opensource.org/licenses/PostgreSQL

- **PostgreSQL v18** — Copyright (c) 1996-2024 The PostgreSQL Global Development Group — https://www.postgresql.org
- **pg_cron** — Copyright (c) Citus Data, Inc. — https://github.com/citusdata/pg_cron
- **pgAdmin 4 v9.15** — Copyright (c) 2013-2024 The pgAdmin Development Team — https://www.pgadmin.org

---

## LGPL-2.1 (optional component)

Licensed under the GNU Lesser General Public License, Version 2.1.
https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html

- **Cockpit** — Copyright (c) Red Hat, Inc. — https://cockpit-project.org
  Cockpit is an optional host-level monitoring tool and is not bundled into
  EVI containers. It runs as a separate system service.
- **cockpit-files** — Copyright (c) Cockpit Project — https://github.com/cockpit-project/cockpit-files
  Official Cockpit File browser. Host-only optional package; not bundled into
  EVI containers.

---

## curl License

Permission to use, copy, modify, and distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

- **curl** — Copyright (c) 1996-2024 Daniel Stenberg — https://curl.se
  Licensed under the curl license (MIT/X-inspired).

---

## GPL-2.0 (host apt package)

Licensed under the GNU General Public License, Version 2.
https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

- **uidmap** — shadow project contributors — https://manpages.debian.org/uidmap
  Host apt package for rootless Podman user namespaces. Not linked into evi.

---

## GPL-3.0 (host apt package)

Licensed under the GNU General Public License, Version 3.
https://www.gnu.org/licenses/gpl-3.0.html

- **ufw** — Copyright (c) Canonical Ltd. — https://launchpad.net/ufw
  Host apt package for the host firewall. Not linked into evi.

---

## Unlicense

- **big-integer** — Peter Olson — https://github.com/peterolson/BigInteger.js

---

## Alpine Linux

The EVI backend and worker containers are based on Alpine Linux 3.21.
Alpine Linux packages are distributed under various open source licenses
(primarily MIT, GPL-2.0, BSD). See https://alpinelinux.org for details.

---

*This file is generated during the release process.
Last updated: 2026-09-07*
