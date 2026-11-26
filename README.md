# LifeCheckpoint

**Multi-Platform Application in Emergency Monitoring and Disaster Preparedness (City of Manila)**

LifeCheckpoint is an offline-first Progressive Web App (PWA) and Android application built with Flutter, Vercel Serverless Functions, and Supabase PostgreSQL to help City of Manila households prepare 72-hour Go-Bags, monitor live local hazards, locate nearby evacuation centers, and coordinate with local DRRM administrators.

---

## Tech Stack

| Layer | Technology | Purpose |
| :--- | :--- | :--- |
| **Frontend** | **Flutter** (Web PWA + Android) | Responsive Material 3 UI, offline Service Worker caching, weighted Go-Bag tracker, interactive City of Manila shelter map, disaster guides, hotlines, survival tools, and ISO/IEC 25010 survey. |
| **Backend API** | **Node.js & TypeScript** on **Vercel** ([`api/index.ts`](api/index.ts), [`server/lib/`](server/lib/)) | Serverless `/api/*` REST API for authentication, family household sync, cached weather/seismic telemetry, Gmail 6-digit OTP password reset, Admin RBAC operations, and RA 10173 data erasure. |
| **Database** | **Supabase PostgreSQL 17** ([`supabase/schema.sql`](supabase/schema.sql)) | Cloud relational storage with Row-Level Security (RLS) for households, users, kit items, evacuation centers, safety check-ins, DRRM advisories, telemetry cache, and ISO/IEC 25010 evaluations. |

---

## Core Modules

- **Go-Bag Readiness & Expiry Tracking:** 72-hour household supply checklist scaled by family composition with weighted scoring (Water/Food & Medical 3×; Tools/Documents/Special Needs 2×; Sanitation/Clothing 1×) and replacement alerts.
- **Live Weather, Flood & Seismic Monitoring:** City of Manila weather, PAGASA Heat Index, 6-hour rain forecast (Open-Meteo), Luzon/Manila earthquakes (USGS), Manila flood-watch corridors, official DRRMO advisories, and family safety check-ins.
- **Interactive City of Manila Map:** Offline-cacheable OpenStreetMap view covering 8 official Manila evacuation centers, 9 hospitals, 20 MPD/BFP stations, GPS distance/bearing, full-screen map view, and custom Barangay shelter pinning.
- **Safety Hub & Offline Survival Tools:** Before/During/After disaster checklists, 36 Manila/National emergency hotlines with GPS distress SMS, Family Emergency Plan, Web Audio rescue whistle, SOS Morse strobe, and flashlight.
- **Admin & DRRM Operations Portal:** Dedicated role-based portal for household readiness monitoring, shelter Open/Standby management, check-in assistance acknowledgment, advisory broadcasting, and ISO/IEC 25010 CSV export.

---

## Setup & Deployment

### 1. Database (Supabase)
1. Create a PostgreSQL project on [supabase.com](https://supabase.com).
2. Run [`supabase/schema.sql`](supabase/schema.sql) in the SQL Editor (also auto-verified on first API request).
3. Copy the Transaction Pooler connection URI (port `6543`).

### 2. Web & API Hosting (Vercel)
1. Import this repository into Vercel (configured via [`vercel.json`](vercel.json) and [`scripts/build-web.mjs`](scripts/build-web.mjs)).
2. Configure the environment variables listed in [`.env.example`](.env.example):
   - `SUPABASE_DB_URL`
   - `JWT_SECRET`
   - `ADMIN_INVITE_CODE`
   - `GMAIL_USER`
   - `GMAIL_APP_PASSWORD`
3. Deploy to publish the live PWA and `/api/*` backend.

### 3. Android Release Build (Optional)
```bash
flutter build apk --release --dart-define=API_BASE_URL=https://lifecheckpoint.vercel.app
```

### 4. Automated Tests
```bash
npm run typecheck
npm run test:api
flutter test
```
