# ReadFlow

ReadFlow reads text out loud for you.

Pick some text anywhere on your Mac. Press a key. ReadFlow speaks it. Each word
lights up as it is read, so your eyes can follow along.

It is built for people who find reading hard. It is calm, simple, and it works
the moment you open it.

ReadFlow lives in the **menu bar** at the top of your screen. There is no Dock
icon and no big window in the way.

## What it can read

- Text you select in almost any app.
- PDFs (open one with **Open PDF…** in the menu). It can even read scanned PDFs.

## The three voices

You choose the voice in the menu bar. You can switch any time.

1. **System** — the built-in Mac voice. It is the default. It works right away,
   with no setup. Start here.
2. **Kokoro** — a natural-sounding voice that runs on your own Mac. Nothing
   goes to the internet. It needs a one-time setup. See
   [`kokoro/README.md`](kokoro/README.md).
3. **Azure** — an optional cloud voice from Microsoft. It needs an account and a
   key. Only set this up if you want it. Your key is stored safely in the Mac
   Keychain. It is never shown and never saved in plain text.

You can use ReadFlow fully with just the System voice.

## How to build it

You need Apple's Command Line Tools (no full Xcode needed).

Open Terminal and run:

```sh
cd "/Users/tylerfreund/Desktop/Coding Projects/ReadFlow"
bash scripts/build_app.sh
```

When it finishes, the app is here:

```
build/ReadFlow.app
```

Open it:

```sh
open "build/ReadFlow.app"
```

Look for the ReadFlow icon in your menu bar.

## One-time permission

The first time, ReadFlow needs permission to see the text you select.

1. Open **System Settings**.
2. Go to **Privacy & Security**, then **Accessibility**.
3. Turn **ON** the switch next to **ReadFlow**.

If ReadFlow is not in the list, click the **+** button and add it from
`build/ReadFlow.app`.

That is it. You only do this once.

If you skip this, ReadFlow still reads PDFs you open with **Open PDF…**.

## The hotkey

Select text. Then press:

> **Option-R**

ReadFlow reads it out loud.

You can also use the menu bar: click the ReadFlow icon, then **Read Selection**.
**Stop** stops it.

## Making it easy to read (the HUD)

When ReadFlow reads, a small floating panel shows the words. The word being
spoken is highlighted. You can change how it looks in **Settings** so it is
easy on your eyes:

- **OpenDyslexic font** — a font made to be easier to read.
- **Bigger text** — set the size you like.
- **More space between lines** — give each line room to breathe.
- **More space between letters** — spread the letters out.
- **Speed** — read slower or faster.

Change these until reading feels comfortable. There is no wrong setting.

## If something does not work

- **No sound** — make sure a voice is picked in the menu and your Mac volume is
  up. The System voice always works; if Kokoro or Azure is down, ReadFlow tells
  you and offers the System voice.
- **It cannot read my selection** — check the Accessibility permission above.
- **Kokoro voice not working** — see [`kokoro/README.md`](kokoro/README.md).

ReadFlow tries hard to never fail quietly. If something is wrong, it will tell
you what to do.
