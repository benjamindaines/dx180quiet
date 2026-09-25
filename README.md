# Welcome to genuine insanity

*"We do not do these things because they're easy. We do them because we thought they would be easy."*

This magisk module is designed to, basically, the complete opposite of how the Android OS handles CPU affinity and background processes. I may have lost a bit (more) sanity working on this, but it genuinely sounds fantastic, runs a hell of a lot cooler, and has much better battery life. Will only get better from this initial release too! 

## What's the goal?

- Stop, disable, kill, etc as many background processes and unnecessary system components as possible.

- Push everything that isn't strictly playback (defined as anything that's not audioserver, the player's decoding thread, or DSP) onto the big CPU cores (4-7) and run them at a reduced speed

- Keep audio playback threads on the little CPU cores (0-3) and run them at a constant, least required speed

- Basically, turn the little CPU cores into a low-powered, dedicated co-processor for music playback

## So, is it crap?

- It's actually pretty sweet

- Quite a bit away from being done, there's still a bunch of kernel processes running on the little CPU cores. If I cannot get them off 0-3, I'll try to at least as much as I can on a single core, leaving 3 cores available for music threads. 

- To my ears, it's an audible improvement. I'm not going to make up a bunch of fancy words to describe the texture and mouth-feel of it, you'll have to judge for yourself. But...

- Objectively runs cooler. By default both the big and little cores are running at full speed all the time when doing anything at all. Which means...

- Better battery life. I haven't measured it properly, but it's better than the 10%/album rate I was consistently getting previously.

## What's the catch?

Right now it's only been used / designed to be used with / tested with Symfonium. But, it's been written in a way that should make it fairly easy to adapt to whatever app you'd like. 

- Use the discovery script to find candidate processes to add to the disable / stop lists. 

- Define the app ID of the music player you're using near the top of the script

- Add to the music engine candidate strings as needed

- Use the whatcpu script to see where threads are actually landing on the CPUs

- Message me on XMPP ben@chat.digitalsand.photography for assistance

Good luck, have fun, don't hurt yourselves. 
