import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { useEffect, useState } from "react";
import { motion } from "framer-motion";
export function EfudaCard({ card, taken, takenBy, isMe, onClick, collectionMode = false }) {
    const [flipped, setFlipped] = useState(false);
    useEffect(() => {
        if (taken && !collectionMode)
            setFlipped(true);
    }, [taken, collectionMode]);
    const handleClick = () => {
        if (taken) {
            setFlipped((f) => !f);
            return;
        }
        onClick();
    };
    return (_jsx("div", { className: `efuda ${taken ? "efuda--taken" : ""} ${isMe && taken ? "efuda--mine" : ""}`, onClick: handleClick, role: "button", tabIndex: 0, onKeyDown: (e) => e.key === "Enter" && handleClick(), "aria-label": card.fuda, children: _jsxs(motion.div, { className: "efuda__inner", animate: { rotateY: flipped ? 180 : 0 }, transition: { duration: 0.4, ease: "easeInOut" }, style: { transformStyle: "preserve-3d", position: "relative" }, children: [_jsxs("div", { className: "efuda__face efuda__face--front", children: [_jsx("img", { src: card.image, alt: card.fuda, className: "efuda__img", onError: (e) => { e.currentTarget.style.display = "none"; } }), _jsx("p", { className: "efuda__fuda", children: card.fuda }), card.source === "custom" && _jsx("span", { className: "efuda__badge", children: "\u30AB\u30B9\u30BF\u30E0" }), taken && takenBy && (_jsx("div", { className: "efuda__taken-overlay", children: _jsx("span", { children: takenBy }) }))] }), _jsxs("div", { className: "efuda__face efuda__face--back", children: [_jsx("p", { className: "efuda__yomi", children: card.yomi }), _jsx("p", { className: "efuda__fuda-back", children: card.fuda })] })] }) }));
}
