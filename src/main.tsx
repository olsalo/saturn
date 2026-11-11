import React from "react";
import ReactDOM from "react-dom/client";
import { isTauri } from "@tauri-apps/api/core";
import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import App from "./app/app";
import { ToastProvider } from "./components/ui/toast";
import "./styles/globals.css";
void i18n.use(initReactI18next).init({
  lng: "en",
  resources: { en: { translation: { loading: "Loading" } } },
  interpolation: { escapeValue: false },
});
if (isTauri()) document.documentElement.dataset.desktop = "true";
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <ToastProvider position="top-center">
      <App />
    </ToastProvider>
  </React.StrictMode>,
);
