import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "ForgeFit Yoga Voice Auditions",
  description: "Compare voices for ForgeFit guided yoga practice.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
