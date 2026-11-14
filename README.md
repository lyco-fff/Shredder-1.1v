# Shredder-1.1v
A windows batch / powershell script that permanently destroys files and folders using cryptographic overwriting and metadata scrubbing, making them completely unrecoverable.

**Set-up and Use**
- Install the .bat
- Run as admin
- Follow instructions in command line

(The script invokes Windows PowerShell 5.1 which ships natively with windows 10 & 11, so no prerequisite installations are required.)

**How it Works**

Simply encrypts, overwrites, and permanently deletes files and folders.

- UAC Token Elevation
- Safeguards protected Windows and profile paths
- Encrypts in place with a unique, throwaway AES-256 key
- Overwrites with random bytes and truncates to zero
- Scrubs file metadata (timestamps and filenames)
- Delete

**Shredder 1v**

Works, but has easily bypassed safeguards. For example, if a folder that is to be deleted contains a Symlinks or Junction, Shredder 1v will end up deleting both the intended folder and the folder the pointer points to. This can lead to a user destroying data they did not intend to destroy. 

Shredder 1.1v fixes this issue.

*for ppl who care*

In windows powershell 5.1, *Get-ChildItem -Recurse* automatically follows directory symbolic links and NTFS junctions. While the loop checks *$sub.Attributes -band [IO.FileAttributes]::ReparsePoint* and skips the junction container itself, *Get-ChildItem -Recurse* still enumerates every file and subfolder inside the junction's target. Because those child items do not carry the *ReparsePoint* flag and their *.FullName* uses the junction's path prefix rather than the target's real path, a junction pointing to C:\Windows or a user profile folder bypasses both the reparse check and *Test-SafetyGuard*.

**DISCLAIMER: RUN AT YOUR OWN RISK.**

I built this tool for personal use, and since I am the only real-world tester, YOU may run into unforeseen edge cases before I do. If you find a bug, please email me at peppereddd@gmail.com with the steps to reproduce the issue so I can test it and push a fix.

**AI Disclosure:**

> 20%-30% of the end-product code was generated using AI. AI was used in the process only to troubleshoot and identify edge-cases and bugs in advance.
