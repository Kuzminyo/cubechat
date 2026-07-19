import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'

export type Lang = 'uk' | 'en'

/* ------------------------------------------------------------------ */
/*  Ukrainian is the base language; English is the switch.            */
/* ------------------------------------------------------------------ */

const uk = {
  nav: {
    features: 'Можливості',
    how: 'Як це працює',
    security: 'Безпека',
    source: 'Код',
    cta: 'Встановити',
    menuOpen: 'Відкрити меню',
    menuClose: 'Закрити меню',
  },
  hero: {
    badge: 'Поза мережею · наскрізне шифрування',
    title: { a: 'Повідомлення, яким\nне потрібен ', em: 'сигнал', b: '.' },
    subtitle:
      'cubechat передає ваші слова від телефона до телефона через Bluetooth-мережу — зашифровано, анонімно й без сервера. Без вишок, без акаунтів, без слідів.',
    ctaPrimary: 'Встановити',
    ctaSecondary: 'Як це працює',
    chips: ['без акаунтів', 'без серверів', 'без інтернету'],
    meshLive: 'мережа активна',
    relaying: 'ретрансляція поруч',
    scroll: 'гортати',
  },
  marquee: [
    '246 тестів пройдено',
    '0 серверів',
    '0 номерів телефона',
    'рукостискання Noise XX',
    'пряма секретність X3DH',
    'багатохопова ретрансляція',
    'AES-шифрування на диску',
    'анонімність за замовчуванням',
    'відкритий код',
  ],
  how: {
    kicker: 'Як це працює',
    title: 'Повідомлення знаходить свій шлях,\nодин телефон за раз.',
    caption: 'одне повідомлення · багато хопів · нуль серверів',
    you: 'Ти',
    dest: 'Айша',
    steps: [
      {
        title: 'Поруч — навпростець',
        body:
          'Два телефони в зоні Bluetooth встановлюють взаємно автентифіковану сесію Noise й спілкуються напряму. Посередник не бачить з’єднання.',
      },
      {
        title: 'Далеко — через ретрансляцію',
        body:
          'Занадто далеко? Ваше повідомлення стрибає через телефони між вами. Кожен вузол передає запечатаний конверт, який не може відкрити.',
      },
      {
        title: 'Лише ваше',
        body:
          'Розшифрувати може тільки отримувач. Уся ваша особистість — це один криптографічний ключ, згенерований під час першого запуску. Без пошти, без номера, без реєстрації.',
      },
    ],
  },
  features: {
    kicker: 'Що всередині',
    title: 'Усе, чим має бути месенджер,\nі нічого зайвого.',
    items: [
      {
        title: 'Наскрізне шифрування',
        body:
          'Кожне повідомлення йде взаємно автентифікованою сесією Noise й підписане Ed25519. Вузли передають його, ніколи не розшифровуючи.',
        tag: 'Noise XX · Ed25519',
      },
      {
        title: 'Пряма секретність',
        body:
          'Підписані передключі X3DH та ефемерні ключі дають пряму секретність для кожного повідомлення в асинхронній і багатохоповій доставці.',
        tag: 'X3DH',
      },
      {
        title: 'Анонімність за замовчуванням',
        body:
          'Ім’я пристрою ніколи не транслюється. Безіменні співрозмовники позначаються як «Anonymous ⟨тег⟩», виведений прямо з їхнього відкритого ключа.',
        tag: 'без ідентифікаторів',
      },
      {
        title: 'Зберегти й переслати',
        body:
          'Повідомлення для співрозмовника поза зоною зберігаються зашифрованими й доставляються автоматично, щойно він з’явиться знову.',
        tag: 'офлайн-доставка',
      },
      {
        title: 'Звірка наживо',
        body:
          'Порівняйте два відбитки віч-на-віч, щоб виключити атаку «людина посередині». Звірені співрозмовники отримують щит; зміна ключа знову їх позначає.',
        tag: 'значок-щит',
      },
      {
        title: 'Екстрене стирання',
        body:
          'Потрійний тап по логотипу миттєво стирає всі ключі, контакти й повідомлення з пристрою. Нічого передавати.',
        tag: 'потрійний тап',
      },
      {
        title: 'Групові канали',
        body:
          'Кімнати зі спільним ключем, що транслюються мережею. Передайте співрозмовнику ключ каналу вашим шифрованим 1:1 зв’язком, щоб запросити.',
        tag: '/join #room',
      },
      {
        title: 'Голос і зображення',
        body:
          'Надсилайте фото й голосові, розбиті на частини з підписаним маніфестом і перевіркою збірки SHA-256. Живий сигнал хвилі під час запису.',
        tag: 'підписаний маніфест',
      },
    ],
  },
  security: {
    kicker: 'Криптографія',
    title: { a: 'Не «повірте нам». ', em: 'Перевірте.', b: '' },
    intro:
      'Кожен примітив — з перевірених бібліотек і закріплений відомими тестовими векторами. Обгортка відкрита й у репозиторії — читайте, а не просто вірте.',
    envelopeTitle: 'Дворівневий конверт',
    outer: 'зовнішній шифр',
    outerDesc: 'SealedBox · X3DH · канал — вузли маршрутизують, не розшифровують',
    signedDesc: 'доводить авторство над origin ‖ dest ‖ id ‖ час',
    yourMessage: 'ваше повідомлення',
    messageExample: '«уже йду — 5 хв ✌️»',
    comment:
      '// вузли маршрутизують без розшифрування · отримувач розшифровує · підпис доводить відправника',
    layers: [
      { name: 'Noise XX', purpose: 'Взаємно автентифікована сесія прямим каналом', prim: 'X25519 · ChaCha20-Poly1305 · BLAKE2s' },
      { name: 'X3DH', purpose: 'Пряма секретність для кожного повідомлення (асинхронно / багатохопово)', prim: 'signed prekeys + ephemeral keys' },
      { name: 'SealedBox', purpose: 'Анонімне шифрування; вузли передають, не відкриваючи', prim: 'crypto_box_seal' },
      { name: 'SignedPayload', purpose: 'Доводить, хто написав повідомлення, наскрізно', prim: 'Ed25519' },
      { name: 'Крипто каналів', purpose: 'Групові кімнати зі спільним ключем, вибір за 8-байтним тегом', prim: 'BLAKE2s(name‖pw) · ChaCha20-Poly1305' },
      { name: 'На диску', purpose: 'Історія, список контактів і ключі на пристрої', prim: 'AES Hive boxes · OS Keystore / Keychain' },
    ],
    scopeTitle: 'Межі — прямо.',
    scopeBody:
      'Групові канали мають один симетричний ключ — без прямої секретності для кожного відправника (для цього потрібен груповий протокол на кшталт MLS, поза межами). Автентичність автора все одно тримається на підписі Ed25519. Краще ми скажемо, ніж ви припускатимете.',
  },
  philosophy: {
    quote:
      '«cubechat постав із простої відмови — що зв’язок із людьми поруч не має вимагати компанії посередині. Жодного акаунта, жодного сервера, якому треба довіряти, жодного номера. Лише телефони в кімнаті, мережа між ними й шифрування, яке можна прочитати самому. Приватність не має бути налаштуванням. Вона має бути самою суттю.»',
    attribution: 'Проєкт cubechat — відкритий код',
  },
  download: {
    kicker: 'Почати',
    title: 'Два телефони й кілька метрів.\nОсь і все налаштування.',
    subtitle:
      'Встановіть, згенеруйте ключ — і ви в мережі. Жодного екрана реєстрації, бо немає акаунта, який треба реєструвати.',
    androidTop: 'Завантажити для',
    android: 'Android',
    iosTop: 'Сайдлоад для',
    ios: 'iOS',
    sourceTop: 'Зібрати з',
    source: 'коду',
    note: 'Android і iOS використовують справжній Bluetooth · веб і десктоп лише інтерфейс',
  },
  footer: {
    tagline:
      'Зашифрований, анонімний, безсерверний обмін повідомленнями через Bluetooth LE-мережу. Без акаунтів. Без серверів. Без інтернету.',
    cols: [
      {
        head: 'Продукт',
        links: [
          { label: 'Можливості', href: '#features' },
          { label: 'Як це працює', href: '#how' },
          { label: 'Безпека', href: '#security' },
          { label: 'Завантажити', href: '#download' },
        ],
      },
      {
        head: 'Криптографія',
        links: [
          { label: 'Noise XX', href: '#security' },
          { label: 'Пряма секретність X3DH', href: '#security' },
          { label: 'Підписи Ed25519', href: '#security' },
          { label: 'Резерв NIP-44', href: '#security' },
        ],
      },
      {
        head: 'Проєкт',
        links: [
          { label: 'Натхнено bitchat ↗', href: 'https://github.com/permissionlesstech/bitchat' },
          { label: 'Зроблено на Flutter ↗', href: 'https://flutter.dev' },
          { label: 'Дорожня карта', href: '#' },
          { label: 'Ліцензія', href: '#' },
        ],
      },
    ],
    rights: 'нічого логувати, нікому довіряти',
    e2e: 'наскрізне шифрування',
  },
}

type Dict = typeof uk

const en: Dict = {
  nav: {
    features: 'Features',
    how: 'How it works',
    security: 'Security',
    source: 'Source',
    cta: 'Get the app',
    menuOpen: 'Open menu',
    menuClose: 'Close menu',
  },
  hero: {
    badge: 'Off-grid · end-to-end encrypted',
    title: { a: 'Messages that need\nno ', em: 'signal', b: '.' },
    subtitle:
      'cubechat carries your words phone-to-phone across a Bluetooth mesh — encrypted, anonymous, and serverless. No towers, no accounts, no trace.',
    ctaPrimary: 'Get the app',
    ctaSecondary: 'See how it works',
    chips: ['no accounts', 'no servers', 'no internet'],
    meshLive: 'mesh live',
    relaying: 'relaying nearby',
    scroll: 'scroll',
  },
  marquee: [
    '246 passing tests',
    '0 servers',
    '0 phone numbers',
    'Noise XX handshake',
    'X3DH forward secrecy',
    'multi-hop mesh relay',
    'AES-encrypted at rest',
    'anonymous by default',
    'open source',
  ],
  how: {
    kicker: 'How it works',
    title: 'A message finds its way,\none phone at a time.',
    caption: 'one message · many hops · zero servers',
    you: 'You',
    dest: 'Aisha',
    steps: [
      {
        title: 'In range, direct',
        body:
          'Two phones within Bluetooth range form a mutually-authenticated Noise session and talk peer-to-peer. No middle-man ever sees the link.',
      },
      {
        title: 'Out of range, relayed',
        body:
          'Too far apart? Your message hops through the phones in between. Each relay forwards a sealed envelope it cannot open.',
      },
      {
        title: 'Yours alone',
        body:
          'Only the recipient can decrypt it. Your entire identity is one cryptographic key you generate on first launch — no email, no number, no sign-up.',
      },
    ],
  },
  features: {
    kicker: "What's inside",
    title: 'Everything a messenger should be,\nand nothing it shouldn’t.',
    items: [
      {
        title: 'End-to-end encrypted',
        body:
          'Every message rides a mutually-authenticated Noise session and is signed with Ed25519. Relays route it without ever decrypting.',
        tag: 'Noise XX · Ed25519',
      },
      {
        title: 'Forward secrecy',
        body:
          'X3DH signed prekeys and ephemeral keys give per-message forward secrecy for async and multi-hop delivery.',
        tag: 'X3DH',
      },
      {
        title: 'Anonymous by default',
        body:
          'No device name is ever broadcast. Unnamed peers appear as “Anonymous ⟨tag⟩”, derived straight from their public key.',
        tag: 'no identifiers',
      },
      {
        title: 'Store & forward',
        body:
          'Messages for a peer who is out of range are held encrypted and delivered automatically the moment they reappear.',
        tag: 'offline delivery',
      },
      {
        title: 'Verify in person',
        body:
          'Compare two fingerprints face-to-face to rule out a man-in-the-middle. Verified peers earn a shield — key changes re-flag them.',
        tag: 'shield badge',
      },
      {
        title: 'Emergency wipe',
        body:
          'Triple-tap the logo to erase every key, peer, and message from the device instantly. Nothing left to hand over.',
        tag: 'triple-tap',
      },
      {
        title: 'Group channels',
        body:
          'Shared-key rooms broadcast across the mesh. Hand a peer the channel key over your encrypted 1:1 link to invite them.',
        tag: '/join #room',
      },
      {
        title: 'Voice & images',
        body:
          'Send photos and voice notes, chunked with a signed manifest and a SHA-256 reassembly check. Live waveform while you record.',
        tag: 'signed manifest',
      },
    ],
  },
  security: {
    kicker: 'Cryptography',
    title: { a: 'Not “trust us”. ', em: 'Verifiable.', b: '' },
    intro:
      "Every primitive comes from vetted libraries and is pinned to known-answer test vectors. The framing is open and in-repo — read it, don't just believe it.",
    envelopeTitle: 'Two-tier envelope',
    outer: 'outer cipher',
    outerDesc: 'SealedBox · X3DH · channel — relays route, never decrypt',
    signedDesc: 'proves authorship over origin ‖ dest ‖ id ‖ time',
    yourMessage: 'your message',
    messageExample: '“on my way — 5 min ✌️”',
    comment:
      '// relays route without decrypting · recipient decrypts · signature proves the sender',
    layers: [
      { name: 'Noise XX', purpose: 'Mutually-authenticated session over a direct link', prim: 'X25519 · ChaCha20-Poly1305 · BLAKE2s' },
      { name: 'X3DH', purpose: 'Per-message forward secrecy for async / multi-hop', prim: 'signed prekeys + ephemeral keys' },
      { name: 'SealedBox', purpose: 'Anonymous encryption relays forward without opening', prim: 'crypto_box_seal' },
      { name: 'SignedPayload', purpose: 'Proves who wrote the message, end-to-end', prim: 'Ed25519' },
      { name: 'Channel crypto', purpose: 'Shared-key group rooms, selected by an 8-byte tag', prim: 'BLAKE2s(name‖pw) · ChaCha20-Poly1305' },
      { name: 'At rest', purpose: 'History, roster and keys on the device', prim: 'AES Hive boxes · OS Keystore / Keychain' },
    ],
    scopeTitle: 'Scope, stated plainly.',
    scopeBody:
      "Group channels share one symmetric key — no per-sender forward secrecy (that needs a group protocol like MLS, out of scope). Author authenticity still holds via the Ed25519 signature. We'd rather tell you than let you assume.",
  },
  philosophy: {
    quote:
      '“cubechat was built on a simple refusal — that reaching the people around you should not require a company in the middle. No account to create, no server to trust, no number to hand over. Just the phones in the room, the mesh between them, and encryption you can read for yourself. Privacy shouldn’t be a setting. It should be the shape of the thing.”',
    attribution: 'The cubechat project — open source',
  },
  download: {
    kicker: 'Get started',
    title: "Two phones and a few metres.\nThat's the whole setup.",
    subtitle:
      "Install it, generate your key, and you're on the mesh. No sign-up screen, because there's no account to sign up for.",
    androidTop: 'Download for',
    android: 'Android',
    iosTop: 'Sideload for',
    ios: 'iOS',
    sourceTop: 'Build from',
    source: 'Source',
    note: 'Android & iOS use real Bluetooth · web & desktop run the UI only',
  },
  footer: {
    tagline:
      'Encrypted, anonymous, serverless messaging over a Bluetooth LE mesh. No accounts. No servers. No internet required.',
    cols: [
      {
        head: 'Product',
        links: [
          { label: 'Features', href: '#features' },
          { label: 'How it works', href: '#how' },
          { label: 'Security', href: '#security' },
          { label: 'Download', href: '#download' },
        ],
      },
      {
        head: 'Cryptography',
        links: [
          { label: 'Noise XX', href: '#security' },
          { label: 'X3DH forward secrecy', href: '#security' },
          { label: 'Ed25519 signatures', href: '#security' },
          { label: 'NIP-44 fallback', href: '#security' },
        ],
      },
      {
        head: 'Project',
        links: [
          { label: 'Inspired by bitchat ↗', href: 'https://github.com/permissionlesstech/bitchat' },
          { label: 'Built with Flutter ↗', href: 'https://flutter.dev' },
          { label: 'Roadmap', href: '#' },
          { label: 'License', href: '#' },
        ],
      },
    ],
    rights: 'nothing to log, nobody to trust',
    e2e: 'end-to-end encrypted',
  },
}

const translations: Record<Lang, Dict> = { uk, en }

type I18nCtxValue = { lang: Lang; setLang: (l: Lang) => void; t: Dict }

const I18nCtx = createContext<I18nCtxValue | null>(null)

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLang] = useState<Lang>(() => {
    const saved = typeof localStorage !== 'undefined' ? localStorage.getItem('cc-lang') : null
    return saved === 'en' || saved === 'uk' ? saved : 'uk'
  })

  useEffect(() => {
    document.documentElement.lang = lang
    try {
      localStorage.setItem('cc-lang', lang)
    } catch {
      /* ignore */
    }
  }, [lang])

  return <I18nCtx.Provider value={{ lang, setLang, t: translations[lang] }}>{children}</I18nCtx.Provider>
}

export function useI18n(): I18nCtxValue {
  const ctx = useContext(I18nCtx)
  if (!ctx) throw new Error('useI18n must be used within I18nProvider')
  return ctx
}
