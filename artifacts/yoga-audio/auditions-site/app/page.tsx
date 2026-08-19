const auditions = [
  { name: "Achernar", voice: "Female", file: "audition_achernar.mp3" },
  { name: "Algieba", voice: "Male", file: "audition_algieba.mp3" },
  { name: "Despina", voice: "Female", file: "audition_despina.mp3" },
  { name: "Orus", voice: "Male", file: "audition_orus.mp3" },
  { name: "Schedar", voice: "Male", file: "audition_schedar.mp3" },
  { name: "Sulafat", voice: "Female", file: "audition_sulafat.mp3" },
  { name: "Umbriel", voice: "Male", file: "audition_umbriel.mp3" },
  { name: "Vindemiatrix", voice: "Female", file: "audition_vindemiatrix.mp3" },
] as const;

export default function Home() {
  return (
    <main className="page-shell">
      <header className="hero">
        <p className="eyebrow">ForgeFit · Yoga audio review</p>
        <h1>Find the calmest voice for guided practice.</h1>
        <p className="intro">
          Use headphones to compare calmness, clarity, pacing, and pronunciation.
          Choose the voice that makes the next pose feel easiest to follow.
        </p>
      </header>

      <section className="audition-list" aria-label="Yoga voice auditions">
        {auditions.map((audition, index) => (
          <article className="audition-card" key={audition.name}>
            <div className="card-heading">
              <span className="number" aria-hidden="true">
                {String(index + 1).padStart(2, "0")}
              </span>
              <div>
                <h2>{audition.name}</h2>
                <p>{audition.voice} voice</p>
              </div>
            </div>
            <audio
              controls
              preload="metadata"
              src={`/audio/${audition.file}`}
              aria-label={`${audition.name}, ${audition.voice} voice audition`}
            />
          </article>
        ))}
      </section>

      <footer>ForgeFit yoga guidance · private review preview</footer>
    </main>
  );
}
