/**
 * Unit tests for the HomePage component.
 * These run in CI on every PR and push.
 */
import React from "react";
import { render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import HomePage from "../app/page";

describe("HomePage", () => {
  it("renders the CI/CD headline", () => {
    render(<HomePage />);
    const headline = screen.getByTestId("headline");
    expect(headline).toBeInTheDocument();
    expect(headline).toHaveTextContent("Hello from CI/CD");
  });

  it("displays an environment badge", () => {
    render(<HomePage />);
    const badge = screen.getByTestId("env-badge");
    expect(badge).toBeInTheDocument();
  });

  it("headline is an h1", () => {
    render(<HomePage />);
    const h1 = screen.getByRole("heading", { level: 1 });
    expect(h1).toHaveTextContent("Hello from CI/CD");
  });
});

describe("smoke string check", () => {
  it("the phrase 'Hello from CI/CD' is present in rendered output", () => {
    const { container } = render(<HomePage />);
    expect(container.innerHTML).toContain("Hello from CI/CD");
  });
});
