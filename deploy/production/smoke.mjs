import assert from 'node:assert/strict'
import fs from 'node:fs'
const base = 'http://127.0.0.1:3187'
const health = await fetch(`${base}/health`).then(r => r.json())
assert.equal(health.status, 'ok')
assert.equal(health.service, 'vm2api')
assert.equal(health.base_url, 'https://vm2api.motion-cover.com')
assert.equal((await fetch(`${base}/console/`)).status, 200)
assert.equal((await fetch(`${base}/api/panel/me`)).status, 401)
assert.equal((await fetch(`${base}/v1/models`)).status, 401)
const login = async (username, password) => fetch(`${base}/api/panel/login`, {
  method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Forwarded-Proto': 'https' },
  body: JSON.stringify({ username, password }),
})
assert.equal((await login('admin', '123456')).status, 401)
const res = await login(process.env.VM2API_ADMIN_USER, process.env.VM2API_ADMIN_PASSWORD)
assert.equal(res.status, 200)
const session = await res.json()
assert.equal(session.ok, true)
assert.ok(session.token)
const cookie = res.headers.get('set-cookie') || ''
assert.match(cookie, /HttpOnly/i)
assert.match(cookie, /Secure/i)
const me = await fetch(`${base}/api/panel/me`, {
  headers: { Authorization: `Bearer ${session.token}` },
}).then(r => r.json())
assert.equal(me.ok, true)
assert.equal(me.user, process.env.VM2API_ADMIN_USER)
assert.equal(me.role, 'admin')
const version = fs.readFileSync('/opt/vm2api/VERSION', 'utf8').trim()
assert.equal(me.version, version)
await fetch(`${base}/api/panel/logout`, {method:'POST',headers:{Authorization:`Bearer ${session.token}`}})
console.log(JSON.stringify({status:'passed',version,checks:['health','console','panel authentication','API authentication','default password rejected','administrator login','secure cookie','running version'],active_vm:health.active_vm}))
