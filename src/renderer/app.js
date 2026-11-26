// 엔진 ↔ 셸 ↔ 화면. 셸이 창의 목록과 마우스가 올라온 방울을 알려 주면 엔진에 넘기고,
// 일어난 일을 화면에 옮긴다. 박자(타이머)가 없다 — 무슨 일이 있을 때만 깬다.

import { createEngine, parseKey } from '../game/engine.js'
import { BOARD, OLD_SIZES, clampScale, mulberry32 } from '../game/tree.js'
import { createView } from '../render/view.js'

const sneaky = window.sneaky || null
const SPOTS = ['right', 'left']
const settings = { hidden: false, spot: 'right', scale: 1, twinkle: true }

// 방울이 어디 달릴지는 켤 때마다 다르다. 씨앗은 여기서만 뽑는다(엔진은 시계를 모른다).
const seed = Date.now() >>> 0
const engine = createEngine({ rng: mulberry32(seed) })
const view = createView(document.getElementById('stage'), { rng: mulberry32(seed ^ 0x9e3779b9) })

function save() {
  sneaky?.saveState({ settings })
}

function report() {
  sneaky?.setSettings({ ...settings })
}

/** 일어난 일을 화면에 옮기고, 방울이 달라졌으면 누를 수 있는 자리를 셸에 다시 알린다. */
function flush() {
  let moved = false
  for (const event of engine.drain()) {
    view.apply(event)
    if (event.type === 'hang' || event.type === 'drop') moved = true
  }
  if (moved) sneaky?.setHits(view.hits())
}

function relayout() {
  if (sneaky) {
    // 창이 곧 판이다. 셸이 크기와 자리를 정하고, 여기서는 그 폭에 맞춰 늘리기만 한다.
    view.setLayout({ x: 0, y: 0, scale: innerWidth / BOARD.w })
  } else {
    const scale = settings.scale
    const x = settings.spot === 'left' ? 16 : innerWidth - BOARD.w * scale - 16
    view.setLayout({ x, y: innerHeight - BOARD.h * scale, scale })
  }
  sneaky?.setHits(view.hits())
  sneaky?.setBody(view.body())
  sneaky?.setGrip(view.grip())
}

function set(key, value) {
  if (key === 'spot' && SPOTS.includes(value)) settings.spot = value
  else if (key === 'scale') settings.scale = clampScale(value)
  else if (key === 'twinkle') settings.twinkle = !!value
  else if (key === 'hidden') settings.hidden = !!value
  else return
  view.setTwinkle(settings.twinkle)
  view.setHidden(settings.hidden)
  if (settings.hidden) { engine.hover(null); flush() }
  relayout()
  report()
  save()
}

async function start() {
  const saved = sneaky ? await sneaky.getState() : null
  const kept = saved?.settings || {}
  if (typeof kept.hidden === 'boolean') settings.hidden = kept.hidden
  if (typeof kept.twinkle === 'boolean') settings.twinkle = kept.twinkle
  if (SPOTS.includes(kept.spot)) settings.spot = kept.spot
  // 예전에는 크기가 셋 중 하나였다(s·m·l). 그 설정도 받아 준다.
  if (typeof kept.scale === 'number') settings.scale = clampScale(kept.scale)
  else if (kept.size in OLD_SIZES) settings.scale = OLD_SIZES[kept.size]

  view.setTwinkle(settings.twinkle)
  view.setHidden(settings.hidden)
  relayout()
  report()
  addEventListener('resize', relayout)

  if (sneaky) {
    sneaky.onSet(set)
    sneaky.onWindows((list, quiet) => { engine.sync(list || [], { quiet: !!quiet }); flush() })
    sneaky.onHover((key) => { engine.hover(settings.hidden ? null : key); flush() })
    sneaky.onPressed((key, result) => { engine.press(key, result); flush() })
    sneaky.onMoved(() => view.settle())
    sneaky.onGrip((on) => view.setGrip(on))
    sneaky.ready() // 이제 들을 수 있다 — 창의 목록을 보내 달라
  } else {
    browserDemo()
  }
}

/** 브라우저에서 열었을 때: 가짜 창들로 돌린다. N 새 창 · P 자리 · S 크기 · T 반짝임 · H 숨기기. */
function browserDemo() {
  document.body.classList.add('browser')
  const apps = ['Safari', 'Xcode', '메모', 'Finder', '터미널', 'Figma', '카카오톡', 'Music']
  let nextId = 1
  let fake = []
  const open = () => fake.push({ id: nextId, app: apps[(nextId++ - 1) % apps.length], pid: 0, min: false, big: false })
  const sync = () => { engine.sync(fake.map((w) => ({ ...w }))); flush() }
  for (let i = 0; i < 6; i++) open()
  sync()

  const under = (e) => view.hits().find((hit) => Math.hypot(hit.x - e.clientX, hit.y - e.clientY) <= hit.r)?.key ?? null
  addEventListener('mousemove', (e) => { engine.hover(under(e)); flush() })
  addEventListener('click', (e) => {
    const key = under(e)
    const hit = parseKey(key)
    if (!hit) return
    engine.press(key, 'ok')
    flush()
    const win = fake.find((w) => w.id === hit.id)
    setTimeout(() => {
      if (hit.kind === 'red') fake = fake.filter((w) => w !== win)
      if (hit.kind === 'yellow') win.min = !win.min
      if (hit.kind === 'green') win.big = !win.big
      sync()
    }, 220)
  })
  addEventListener('keydown', (e) => {
    const key = e.key.toLowerCase()
    if (key === 'n') { open(); sync() }
    if (key === 'h') set('hidden', !settings.hidden)
    if (key === 't') set('twinkle', !settings.twinkle)
    if (key === 'p') set('spot', SPOTS[(SPOTS.indexOf(settings.spot) + 1) % SPOTS.length])
    if (key === 's') set('scale', settings.scale >= 1.3 ? 0.3 : settings.scale + 0.25)
  })
}

// 띄워 놓고 들여다볼 때 쓴다(TREE_DEBUG 의 eval).
window.__treeDebug = () => JSON.stringify({ hits: view.hits(), windows: engine.windows })

start()
