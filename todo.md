# TODO

## Apply user-profile fix to running Keycloak (manual)

**Context:** Commit `559ad7d` made email/firstName/lastName optional in
`keycloak/realm-export-prod.json`, but `start --import-realm` only imports a
realm if it doesn't already exist. The running Keycloak still has the old
profile config, so the "Update Account Information" page keeps appearing at
login. Fix has to be done by hand in the admin console (one-time).

### Part 1 — Realm user profile

1. Open `https://auth.qui-est-qui.lepgu.fr` and log in as the bootstrap admin
   (master realm).
2. Top-left realm switcher → select **qui-est-ce**.
3. Sidebar → **Realm settings** → tab **User profile**.
4. For each of **email**, **firstName**, **lastName**:
   - Click the attribute name.
   - Scroll to **Required field** and turn it off (or, under "Required for",
     uncheck both **Users** and **Admins**).
   - **Save**.
5. **Realm settings** → tab **Login**: confirm **Verify profile** is not set
   as a default action. If it is, turn it off — otherwise every new login
   re-stamps the action on the user.

### Part 2 — Clear stale required actions on existing users

The "Update Account Information" page is also driven by required actions
attached to the user account itself. Part 1 stops new ones from being added,
but existing ones must be removed manually.

1. Sidebar → **Users** → open the affected user.
2. Tab **Details** → field **Required user actions**.
3. Remove `Update Profile` and/or `Verify Profile`.
4. **Save**.
5. Repeat for every user hitting the screen.

### Verify

Log in as one of the fixed users in an incognito window. The Update Account
Information page should not appear.

### Future redeploys

`start --import-realm` won't re-apply realm-export edits on an existing
realm. Either:
- recreate the Keycloak Postgres DB (destructive), or
- mirror any further realm-export changes manually in the admin console, or
- switch to an automated kcadm post-import step in `docker-compose.yml`.
