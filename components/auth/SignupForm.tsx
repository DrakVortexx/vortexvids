"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import {
  PASSWORD_MIN,
  accountErrorText,
  birthdateProblem,
  normalizeUsername,
} from "@/lib/accounts/validation";
import { createClient } from "@/lib/supabase/client";
import { BirthdayFields, birthdayValue, emptyBirthday } from "./BirthdayFields";
import { FieldNote, FormError, OrDivider, TextField } from "./fields";
import { GoogleButton } from "./GoogleButton";
import { YapinButton } from "./YapinButton";
import { useUsernameCheck, usernameNote } from "./useUsernameCheck";

export function SignupForm({ next, yapin = false }: { next: string; yapin?: boolean }) {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [birthday, setBirthday] = useState(emptyBirthday);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const status = useUsernameCheck(username);

  const birthdate = birthdayValue(birthday);
  const ageProblem = birthday.year.length === 4 ? birthdateProblem(birthdate) : null;

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    const name = normalizeUsername(username);
    if (status.state === "invalid" || status.state === "taken") return setError(usernameNote(status).error!);
    if (password.length < PASSWORD_MIN) return setError(`Use ${PASSWORD_MIN} or more characters for your password.`);
    const problem = birthdateProblem(birthdate);
    if (problem) return setError(accountErrorText(problem));

    const supabase = createClient();
    if (!supabase) return setError("database not connected");
    setBusy(true);

    const { data, error } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: {
        // The database trigger reads these and refuses under 13 right away.
        data: { username: name, birthdate },
        // No email confirmation - sign in immediately
      },
    });
    
    if (error) {
      setBusy(false);
      return setError(accountErrorText(error.message));
    }

    // Debug: Check if user was created
    console.log('Signup result:', { data, hasSession: !!data.session, hasUser: !!data.user });

    // Wait a moment for trigger to complete
    await new Promise(resolve => setTimeout(resolve, 1500));

    // Skip the broken complete_signup RPC - update profile directly
    if (data.user?.id) {
      // Update the profile that was created by trigger
      // Note: onboarded is not writable via API, so we only update username
      const { error: updateError } = await supabase
        .from('profiles')
        .update({
          username: name
        })
        .eq('id', data.user.id);
      
      if (updateError) {
        console.error('Profile update error:', updateError);
        setBusy(false);
        return setError('Profile setup failed. Please try logging in.');
      }

      console.log('Profile updated successfully');
      
      // Success - redirect (welcome page will handle onboarding)
      router.push('/welcome?next=' + encodeURIComponent(next));
      router.refresh();
    } else {
      setBusy(false);
      return setError('Signup failed. Please try again.');
    }
  }

  if (sentTo) {
    return (
      <div className="space-y-4 text-[14px] leading-5 text-text">
        <p>
          We sent a link to <strong>{sentTo}</strong>. Open it on this device to finish creating
          your account.
        </p>
        <p className="text-text-2">No email after a few minutes? Check your spam folder.</p>
      </div>
    );
  }

  const note = usernameNote(status);

  return (
    <>
      {/* Google OAuth disabled - use email auth */}
      {/* <GoogleButton label="Sign up with Google" next={next} /> */}
      {yapin && <YapinButton next={next} />}
      {yapin && <OrDivider />}
      <form onSubmit={submit} className="space-y-5" noValidate>
        <TextField
          label="Email"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
        <TextField
          label="Username"
          autoComplete="username"
          autoCapitalize="none"
          spellCheck={false}
          required
          maxLength={25}
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          hint={note.hint}
          error={note.error}
        />
        <TextField
          label="Password"
          type="password"
          autoComplete="new-password"
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          hint={`Use ${PASSWORD_MIN} or more characters`}
        />
        <div>
          <BirthdayFields value={birthday} onChange={setBirthday} />
          <FieldNote
            hint="You must be 13 or older. Your birthday is never shown to anyone."
            error={ageProblem ? accountErrorText(ageProblem) : null}
          />
        </div>
        <FormError message={error} />
        <div className="flex items-center justify-between pt-4">
          <Link
            href={next === "/" ? "/login" : `/login?next=${encodeURIComponent(next)}`}
            className="-ml-2 rounded px-2 py-2 text-[14px] font-medium text-[var(--link)] hover:bg-hover"
          >
            Sign in instead
          </Link>
          <button
            type="submit"
            disabled={busy || !email || !username || !password || !birthdate}
            className="btn-blue !normal-case rounded"
          >
            {busy ? "Creating account" : "Create account"}
          </button>
        </div>
      </form>
    </>
  );
}
