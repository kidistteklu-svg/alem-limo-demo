# Go-Live Setup — client-owned accounts

This takes the site from demo mode (data stays in each browser) to **live mode**
(one shared database: customer bookings from any phone appear in the dispatch
console on any device, team logins are real, settings are shared). Everything
below is set up under accounts the **client owns**, so they are never dependent
on the developer's personal accounts.

Total cost: the domain. Everything else runs on free tiers (limits at the end).

---

## 0. Create the client's accounts (15 minutes)

Use one email address the business controls (e.g. `Alemllc@gmail.com`):

| Account | Sign up at | Why |
|---|---|---|
| GitHub | github.com/signup | holds the website code; Vercel deploys from it |
| Supabase | supabase.com → Start your project | the database |
| Vercel | vercel.com/signup → "Continue with GitHub" (the client's new GitHub) | hosting + the domain |

Domain stays at Squarespace — you only change its DNS records (step 5).

## 1. Move the code into the client's GitHub

In the developer's repo on GitHub: **Settings → General → Danger Zone →
Transfer ownership** → enter the client's GitHub username → confirm.
(Alternative with no transfer: the client clicks **Fork** on the repo.)
Afterwards, add the developer back as a collaborator (**Settings →
Collaborators**) so updates can continue.

## 2. Create the database (Supabase)

1. Supabase dashboard → **New project** → name `alem-limo`, region
   **East US (N. Virginia)**, generate a strong database password and store it
   in a password manager (it is rarely needed again). Wait ~2 minutes.
2. Left sidebar → **SQL Editor → New query** → open `supabase/schema.sql` from
   the repo, paste its entire contents, click **Run**. It should finish with
   "Success, no rows returned". This creates the tables, the security policies,
   and the functions the site calls. Run it once only.
3. **Project Settings → API** (gear icon → API): copy
   - **Project URL** (looks like `https://xxxxxxxx.supabase.co`)
   - **anon public** key (long string starting with `eyJ` or `sb_publishable_`)

   The anon key is *meant* to be public — it only unlocks what the row-level
   security policies allow (reading prices, submitting a ride request). Team
   data is reachable only through password-protected functions.

## 3. Connect the site to the database

Open `config.js` in the repo and fill in the two values:

```js
window.ALEM_CONFIG = {
  supabaseUrl: 'https://xxxxxxxx.supabase.co',
  supabaseKey: 'eyJ...'
};
```

Commit and push. That's the whole switch: the site now shows **"Live database ·
shared across all devices"** in the console header instead of "Demo mode".

## 4. Host it (Vercel)

1. Vercel dashboard → **Add New… → Project** → Import the `alem-limo-demo` repo
   (Vercel asks for GitHub access the first time; grant it for this repo).
2. Framework preset: **Other**. Build command: *leave empty*. Output directory:
   *leave empty* (the site is plain files at the repo root). Click **Deploy**.
   You get a `*.vercel.app` URL in about a minute — verify the site loads.
3. **Settings → Domains → Add** → enter the client's domain (e.g.
   `alemluxury.com`). Vercel shows the DNS records it needs — they are the
   values in step 5 unless Vercel says otherwise.

Every future `git push` to `main` redeploys automatically.

## 5. Point the Squarespace domain at Vercel

Squarespace → **Domains → (the domain) → DNS → DNS settings**:

| Type | Host | Data |
|---|---|---|
| A | `@` | `76.76.21.21` |
| CNAME | `www` | `cname.vercel-dns.com` |

Delete any existing Squarespace records for `@` and `www` that point at
Squarespace's own servers (the ones marked "Squarespace defaults" for the
website — leave email/MX records alone). Back in Vercel, both the bare domain
and `www` turn green once DNS propagates (usually minutes, up to 24 h).
HTTPS certificates are issued automatically.

## 6. First sign-in and hardening (do this immediately)

1. Open the live site → footer → **Team Login** → `admin` / `alem2259`.
2. **Team** tab → **Change my password** → set a strong password. The seeded
   password is in a public repo, so this step is not optional.
3. Add each dispatcher as a team member with their own username and password.
4. **Fleet & Rates** and **Availability**: set real initial fees, per-mile
   rates, dispatch hours, number of cars, and the service-area hub.

## 7. Verify it's truly shared

Book a test ride from a phone (not signed in). Open the console on a laptop:
the request is there under Bookings → New. Delete the test record afterwards.

---

## Free-tier limits and what they mean

| Service | Free tier | Practical meaning |
|---|---|---|
| Supabase database | 500 MB storage, 5 GB egress/month | hundreds of thousands of bookings; years of use |
| Supabase pausing | **pauses after 7 days with zero activity** | a live site with visitors never hits this; if it ever pauses, one click in the dashboard restores it. Pro ($25/mo) removes the rule and adds daily backups |
| Supabase backups | none on free tier | use **Bookings → Export CSV** weekly as a backup, or go Pro |
| Vercel Hobby | 100 GB bandwidth/month | plenty — but Hobby is for **non-commercial** use by Vercel's terms. A business site should be on **Pro ($20/mo)**. Free alternative with commercial use allowed: Cloudflare Pages (same "import from GitHub" flow) |
| Address lookup & mileage | OpenStreetMap community servers | fair-use, no guarantee; the site degrades gracefully ("quoted" distance). Swap to Google/Mapbox keys at real volume |

## 8. Booking alerts — Telegram + email (optional, free)

`supabase/notifications.sql` makes the database itself send alerts the moment
a request arrives (and a confirmation email when the dispatcher clicks
Confirm). No server, no monthly cost.

1. **Telegram (instant alerts to the team's phones):** in Telegram, message
   **@BotFather** → `/newbot` → pick a name and a username ending in `bot` →
   copy the **token**. Open your new bot and tap **Start** (or create a group,
   add the bot, and everyone in it gets alerts). Get the **chat ID** by
   opening `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and
   reading `"chat":{"id":…}`.
2. **Email (optional):** sign up at resend.com (free, 3,000 emails/month) →
   add `alemtransportation.com` → add the DNS records it shows in Squarespace
   → create an API key (`re_…`).
3. Supabase → **SQL Editor** → paste `supabase/notifications.sql` → **Run**.
4. Run the `update public.notify_settings …` statement at the bottom of that
   file with your real values (token, chat ID, optional Resend key, the
   dispatcher's inbox).
5. Run `select public.notify_test();` — a test message appears in Telegram
   (and the inbox, if email is set up). Done.

Keys live in a private table the website cannot read. A notification failure
never blocks a booking.

## What is still not included

- **SMS texts.** Possible via Twilio (~$1/month + ~$0.008/text), but US
  carriers require A2P 10DLC business registration first (a one-time ~$20 and
  a few days). Telegram covers the same need for free, so add SMS only if the
  owner specifically wants texts.
- **Online payment.** By design: the dispatcher quotes and accepts each ride.

## Security model, in one paragraph

The browser talks to Supabase with the public anon key. Row-level security
lets anonymous visitors read prices/settings and approved reviews, and insert
exactly one kind of row each into `bookings` (status `new`) and `reviews`
(unapproved). They can read nothing else. Every console action is a database
function that first validates a 12-hour session token issued by
`team_login`, which checks a bcrypt-hashed password. Team passwords are never
stored or sent in plain text in live mode.
