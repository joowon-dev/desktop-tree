import { describe, it, expect } from 'vitest'
import { createEngine, KINDS, MAX_WINDOWS, keyOf, parseKey } from '../src/game/engine.js'
import { BALL, CX, HANG, STAR, TIERS, TRUNK, bodyBands, fits, halfWidthAt, mulberry32, pickSpot } from '../src/game/tree.js'
import { fall, BOUNCE } from '../src/game/fall.js'

const win = (id, more = {}) => ({ id, app: `앱${id}`, pid: 100 + id, ...more })
const types = (events) => events.map((e) => e.type)

describe('트리의 모양', () => {
  it('잎의 폭은 층의 숫자 그대로다', () => {
    expect(halfWidthAt(470)).toBe(176) // 맨 아래 층의 밑
    expect(halfWidthAt(137)).toBeCloseTo(40) // 맨 위 층의 한가운데: 80 의 절반
    expect(halfWidthAt(78)).toBe(0) // 꼭대기
    expect(halfWidthAt(50)).toBe(0) // 별이 있는 데는 잎이 없다
    // 두 층이 겹치는 높이에서는 넓은 쪽: 위 층 80×(112/118)=75.9 > 아래 층 114×(40/138)=33.0
    expect(halfWidthAt(190)).toBeCloseTo((80 * 112) / 118)
  })

  it('방울은 잎 안쪽에만 달린다', () => {
    expect(fits(CX, 300)).toBe(true)
    expect(fits(CX + 176, 460)).toBe(false) // 맨 끝은 가장자리다
    expect(fits(CX, HANG.top - 1)).toBe(false)
    expect(fits(CX, HANG.bottom + 1)).toBe(false)
    expect(fits(CX - 200, 300)).toBe(false) // 잎 밖
  })

  it('고른 자리는 전부 잎 안이고, 방울 36개가 서로 겹치지 않는다', () => {
    for (const seed of [1, 7, 2026, 99999]) {
      const rng = mulberry32(seed)
      const taken = []
      for (let i = 0; i < 36; i++) taken.push(pickSpot(taken, rng))
      let nearest = Infinity
      for (let a = 0; a < taken.length; a++) {
        expect(fits(taken[a].x, taken[a].y)).toBe(true)
        for (let b = a + 1; b < taken.length; b++) {
          nearest = Math.min(nearest, Math.hypot(taken[a].x - taken[b].x, taken[a].y - taken[b].y))
        }
      }
      expect(nearest).toBeGreaterThan(BALL * 2 + 4) // 방울 둘의 지름보다 넉넉히
    }
  })

  it('아무 데나 달린다 — 한 줄로 서지도 한쪽에 몰리지도 않는다', () => {
    const rng = mulberry32(42)
    const taken = []
    for (let i = 0; i < 30; i++) taken.push(pickSpot(taken, rng))
    expect(taken.filter((s) => s.x < CX).length).toBeGreaterThan(8)
    expect(taken.filter((s) => s.x > CX).length).toBeGreaterThan(8)
    expect(taken.filter((s) => s.y < 300).length).toBeGreaterThan(5)
    expect(taken.filter((s) => s.y > 380).length).toBeGreaterThan(5)
  })

  it('같은 씨앗이면 같은 자리다', () => {
    const run = (seed) => {
      const rng = mulberry32(seed)
      const taken = []
      for (let i = 0; i < 9; i++) taken.push(pickSpot(taken, rng))
      return taken
    }
    expect(run(5)).toEqual(run(5))
    expect(run(5)).not.toEqual(run(6))
  })

  it('잡고 끌 수 있는 몸통은 별·잎·기둥이고, 방울이 달리는 자리는 전부 그 안이다', () => {
    const bands = bodyBands()
    const inside = (x, y) => bands.some((b) => x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h)
    expect(inside(STAR.x, STAR.y)).toBe(true)
    expect(inside(TRUNK.x + 5, TRUNK.y + TRUNK.h - 2)).toBe(true)
    expect(inside(CX, 300)).toBe(true)
    expect(inside(CX - 170, 465)).toBe(true) // 맨 아래 층의 끝
    expect(inside(CX - 170, 200)).toBe(false) // 위쪽 잎의 옆 허공
    expect(inside(20, 300)).toBe(false)
    expect(inside(CX + 60, TRUNK.y + TRUNK.h + 20)).toBe(false) // 눈 더미는 안 잡힌다
    const rng = mulberry32(3)
    const taken = []
    for (let i = 0; i < 40; i++) taken.push(pickSpot(taken, rng))
    for (const spot of taken) expect(inside(spot.x, spot.y)).toBe(true)
  })

  it('층은 위에서 아래로 넓어진다', () => {
    for (let i = 1; i < TIERS.length; i++) expect(TIERS[i].half).toBeGreaterThan(TIERS[i - 1].half)
  })
})

describe('창과 방울', () => {
  it('창 하나에 빨강·노랑·초록 셋이 달린다 — 서로 다른 자리에', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(7)])
    const events = engine.drain()
    expect(types(events)).toEqual(['hang'])
    const { spots } = events[0].win
    expect(Object.keys(spots)).toEqual(['red', 'yellow', 'green'])
    expect(spots.red).not.toEqual(spots.yellow)
    expect(spots.yellow).not.toEqual(spots.green)
  })

  it('한 창의 셋은 붙어 있지 않다 — 한 묶음이 아니라 흩어진다', () => {
    let apart = 0
    for (let seed = 1; seed <= 20; seed++) {
      const engine = createEngine({ rng: mulberry32(seed) })
      engine.sync([win(1)])
      const { red, yellow, green } = engine.drain()[0].win.spots
      if (Math.hypot(red.x - yellow.x, red.y - yellow.y) > 80 && Math.hypot(yellow.x - green.x, yellow.y - green.y) > 80) apart++
    }
    expect(apart).toBe(20)
  })

  it('같은 목록이 또 와도 아무 일도 없다', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(1), win(2)])
    engine.drain()
    engine.sync([win(1), win(2)])
    expect(engine.drain()).toEqual([])
  })

  it('창이 닫히면 그 창의 방울이 떨어진다 — 다른 창의 것은 그대로다', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(1), win(2), win(3)])
    const hung = engine.drain()
    engine.sync([win(1), win(3)])
    const events = engine.drain()
    expect(types(events)).toEqual(['drop'])
    expect(events[0].win.id).toBe(2)
    expect(events[0].win.spots).toEqual(hung[1].win.spots) // 달렸던 그 자리에서 떨어진다
    expect(engine.windows.map((w) => w.id)).toEqual([1, 3])
  })

  it('데스크탑을 옮긴 것은 닫힌 것이 아니다 — 조용히 바뀐다', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(1)])
    expect(engine.drain()[0].quiet).toBe(false)
    engine.sync([win(2)], { quiet: true })
    const events = engine.drain()
    expect(types(events)).toEqual(['drop', 'hang'])
    expect(events.every((e) => e.quiet)).toBe(true)
  })

  it('접으면 불이 꺼지고 펴면 켜진다. 키우면 자라고 되돌리면 줄어든다', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(1)])
    engine.drain()
    engine.sync([win(1, { min: true })])
    expect(engine.drain()).toEqual([{ type: 'dim', id: 1 }])
    engine.sync([win(1, { min: false, big: true })])
    expect(engine.drain()).toEqual([{ type: 'lit', id: 1 }, { type: 'grow', id: 1 }])
    engine.sync([win(1)])
    expect(engine.drain()).toEqual([{ type: 'shrink', id: 1 }])
  })

  it(`창은 ${MAX_WINDOWS}개까지만 달고, 자리가 나면 기다리던 창이 달린다`, () => {
    const engine = createEngine({ rng: mulberry32(1) })
    const many = Array.from({ length: MAX_WINDOWS + 2 }, (_, i) => win(i + 1))
    engine.sync(many)
    expect(engine.drain().length).toBe(MAX_WINDOWS)
    engine.sync(many.slice(1)) // 첫 창이 닫혔다
    const events = engine.drain()
    expect(types(events)).toEqual(['drop', 'hang'])
    expect(events[1].win.id).toBe(MAX_WINDOWS + 1)
  })
})

describe('마우스', () => {
  it('키는 "창번호:색" 이다', () => {
    expect(keyOf(12, 'red')).toBe('12:red')
    expect(parseKey('12:red')).toEqual({ id: 12, kind: 'red' })
    expect(parseKey('12:blue')).toBe(null)
    expect(parseKey('x:red')).toBe(null)
    expect(parseKey(null)).toBe(null)
    expect(KINDS).toEqual(['red', 'yellow', 'green'])
  })

  it('올라온 방울이 바뀔 때만 일이 일어난다', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(1)])
    engine.drain()
    engine.hover('1:red')
    engine.hover('1:red')
    expect(engine.drain()).toEqual([{ type: 'hover', id: 1, kind: 'red' }])
    engine.hover('1:green')
    engine.hover(null)
    engine.hover(null)
    expect(engine.drain()).toEqual([{ type: 'hover', id: 1, kind: 'green' }, { type: 'hover', id: null, kind: null }])
  })

  it('없는 창의 방울에는 올라올 수도 누를 수도 없다', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(1)])
    engine.drain()
    engine.hover('9:red')
    engine.press('9:red', 'ok')
    engine.press('1:purple', 'ok')
    expect(engine.drain()).toEqual([])
  })

  it('누른 결과를 그대로 전한다', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(1)])
    engine.drain()
    engine.press('1:red', 'ok')
    engine.press('1:green', 'denied')
    expect(engine.drain()).toEqual([
      { type: 'press', id: 1, kind: 'red', result: 'ok' },
      { type: 'press', id: 1, kind: 'green', result: 'denied' },
    ])
  })

  it('올려 둔 방울의 창이 닫히면 올라온 것도 풀린다', () => {
    const engine = createEngine({ rng: mulberry32(1) })
    engine.sync([win(1)])
    engine.hover('1:red')
    engine.drain()
    engine.sync([])
    expect(types(engine.drain())).toEqual(['hover', 'drop'])
  })
})

describe('떨어지는 방울', () => {
  const from = { x: 300, y: 200, vx: 100, floor: 512, radius: 9 }

  it('바닥에 닿아 멈춘다 — 바닥을 뚫지 않는다', () => {
    const path = fall(from)
    const last = path.frames[path.frames.length - 1]
    expect(last.y).toBe(512 - 9)
    expect(Math.max(...path.frames.map((f) => f.y))).toBe(512 - 9)
    expect(last.t).toBe(path.duration)
    expect(path.frames[0]).toEqual({ t: 0, x: 300, y: 200, rot: 0 })
  })

  it('처음 닿는 데 걸리는 시간은 자유낙하 그대로다', () => {
    // 303px 를 2200px/s² 로: √(2·303/2200) = 0.525초
    const path = fall(from)
    const landed = path.frames.find((f) => f.y === 512 - 9)
    expect(landed.t).toBeGreaterThan(0.51)
    expect(landed.t).toBeLessThan(0.54)
  })

  it('튈 때마다 낮아진다', () => {
    const { bounces } = fall(from)
    expect(bounces.length).toBeGreaterThanOrEqual(3)
    for (let i = 1; i < bounces.length; i++) expect(bounces[i] / bounces[i - 1]).toBeCloseTo(BOUNCE, 1)
    expect(bounces[0]).toBeCloseTo(Math.sqrt(2 * 2200 * 303) * BOUNCE, -1) // 닿은 속도 1155 의 46%
  })

  it('민 쪽으로 굴러가고 그쪽으로 돈다', () => {
    const right = fall(from)
    const left = fall({ ...from, vx: -100 })
    const end = (path) => path.frames[path.frames.length - 1]
    expect(end(right).x).toBeGreaterThan(330)
    expect(end(left).x).toBeLessThan(270)
    expect(end(right).rot).toBeGreaterThan(0)
    expect(end(left).rot).toBeLessThan(0)
    expect(end(right).x - 300).toBeCloseTo(300 - end(left).x)
  })

  it('시간은 앞으로만 가고, 길은 3초 안에 끝난다', () => {
    const path = fall(from)
    for (let i = 1; i < path.frames.length; i++) expect(path.frames[i].t).toBeGreaterThan(path.frames[i - 1].t)
    expect(path.duration).toBeLessThan(3)
    expect(path.duration).toBeGreaterThan(1)
  })
})
