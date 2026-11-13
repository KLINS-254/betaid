# ADSBETA — starter MVP

A mobile-first advertising engagement and rewards portal built with React, Vite and Supabase.

## Included
- Email/password registration and login
- Member dashboard, wallet summary, ad task list and task submissions
- Referral code display
- Manual M-Pesa deposit references (disabled by default; administrator can enable)
- Withdrawal requests and transaction history
- Admin-only task management, payment review and M-Pesa maintenance settings
- Supabase Row Level Security (RLS), database functions and audit log
- Responsive layout for Android/mobile and desktop

## Important launch safeguards
This is a starter implementation, not a fully audited financial product. Before accepting real money:
1. Review the SQL and test all flows using a separate test Supabase project.
2. Confirm your advertising tasks represent genuine advertiser activity. Do not promise guaranteed returns or pay rewards for fake clicks, fabricated views, or deceptive engagement.
3. Set clear terms, eligibility, fees, withdrawal processing times, privacy notice and support contacts.
4. Verify each M-Pesa receipt in the official provider channel before approving a deposit. Never credit from a screenshot alone.
5. Review Kenyan legal, consumer-protection, tax and data-protection requirements with qualified advisers.
6. Use server-side validation and independent security review before production. Never add a Supabase service-role key to frontend environment variables.

## Local setup
1. Create a Supabase project.
2. In Supabase SQL Editor, run `supabase/schema.sql`.
3. Copy `.env.example` to `.env` and fill in the Project URL and anon/public key.
4. Run:
   ```bash
   npm install
   npm run dev
   ```
5. Open the local URL printed by Vite.

## Make an administrator
1. Register your own account through the app.
2. In Supabase SQL Editor, run the admin promotion statement at the bottom of `supabase/schema.sql`, replacing `YOUR_ADMIN_EMAIL` with the email used for registration.
3. Sign out and sign in again.

Never allow users to change their own `role`. Do not expose the service-role key in Vercel.

## Vercel deployment
- Import the GitHub repository into Vercel.
- Framework preset: Vite.
- Build command: `npm run build`
- Output directory: `dist`
- Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in Vercel Project Settings → Environment Variables.
- Redeploy after adding or changing environment variables.

## Manual M-Pesa mode
- Admin → Platform settings.
- Set the paybill/till/phone details and payee name after confirming ownership.
- Set the notice to explain that automatic M-Pesa integration is under maintenance.
- Enable manual deposits only when an official payment destination is configured and monitored.
- Members submit the transaction reference. The wallet is credited only after admin approval.

## Current limitations / next engineering steps
- Ad task submissions are reviewed in Admin → Payment requests; approved tasks credit the published reward.
- Referral attribution and referral bonus rules are not implemented.
- Withdrawal approval records the approved amount as withdrawn; actual M-Pesa payout is still a manual external action and should be reconciled by the admin.
- Add server-side rate limits, email verification policy, password reset UX, CAPTCHA/abuse controls, comprehensive audit views, and automated tests before production.
